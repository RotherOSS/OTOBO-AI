# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
# Copyright (C) 2019-2026 Rother OSS GmbH, https://otobo.io/
# --
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
# --

package Kernel::GenericInterface::Operation::Ticket::QueryEmbeddings;

use v5.24;
use strict;
use warnings;

use parent qw(
    Kernel::GenericInterface::Operation::Ticket::TicketUpdate
);

# core modules
use Scalar::Util qw(reftype);
use MIME::Base64 qw(encode_base64);

# CPAN modules

# OTOBO modules
use Kernel::System::VariableCheck qw(IsArrayRefWithData IsHashRefWithData IsString IsStringWithData);

our $ObjectManagerDisabled = 1;

=head1 NAME

Kernel::GenericInterface::Operation::Ticket::QueryEmbeddings - Query AI Embeddings (Similar Items)

=head1 PUBLIC INTERFACE

=head2 new()

usually, you want to create an instance of this
by using C<Kernel::GenericInterface::Operation->new();>.

=cut

sub new {
    my ( $Type, %Param ) = @_;

    my $Self = bless {}, $Type;

    # check needed objects
    for my $Needed (qw( DebuggerObject WebserviceID )) {
        if ( !$Param{$Needed} ) {
            return {
                Success      => 0,
                ErrorMessage => "Got no $Needed!",
            };
        }

        $Self->{$Needed} = $Param{$Needed};
    }

    $Self->{Config}    = $Kernel::OM->Get('Kernel::Config')->Get('GenericInterface::Operation::QueryEmbeddings');
    $Self->{Operation} = $Param{Operation};

    return $Self;
}

=head2 Run()

perform query-vector-db for similar items Operation.

    my $Result = $OperationObject->Run(
        Data => {
            UserLogin         => 'some agent login',                            # UserLogin or CustomerUserLogin or SessionID is
                                                                                #   required
            SessionID         => 123,

            Password  => 'some password',                                       # if UserLogin or customerUserLogin is sent then
                                                                                #   Password is required

            TicketID     => 123,                                                # TicketID or TicketNumber is required
            TicketNumber => '2004040510440485',

            Collection  => 'faqs',
            Labels      => [],
            FullText    => 0|1,
            Limit       => 3, # default
            Query       => 'searchterm',
       },
    );

    $Result = {
        Success         => 1,                       # 0 or 1
        ErrorMessage    => '',                      # in case of error
        Data            => [
            {
                'id' => '13f89461-cb36-489e-b294-e85d8dc67ca2',
                'metadata' => {
                    'fulltext' => '<the FAQ solution fulltext>',
                    'label' => 'default',
                    'source_id' => '1'      # FAQ ItemID
                },
                'page_content' => '<the FAQ title, sypthom and problem fields>',
                'type' => 'Document'
            },
        ],
    };

=cut

sub Run {
    my ( $Self, %Param ) = @_;

    my $Result = $Self->Init(
        WebserviceID => $Self->{WebserviceID},
    );

    if ( !$Result->{Success} ) {
        $Self->ReturnError(
            ErrorCode    => 'Webservice.InvalidConfiguration',
            ErrorMessage => $Result->{ErrorMessage},
        );
    }

    # check needed stuff
    if ( !IsHashRefWithData( $Param{Data} ) ) {
        return $Self->ReturnError(
            ErrorCode    => 'QueryEmbeddings.EmptyRequest',
            ErrorMessage => "QueryEmbeddings: The request data is invalid!",
        );
    }

    if ( !$Param{Data}->{TicketID} && !$Param{Data}->{TicketNumber} ) {
        return $Self->ReturnError(
            ErrorCode    => 'QueryEmbeddings.MissingParameter',
            ErrorMessage => "QueryEmbeddings: TicketID or TicketNumber is required!",
        );
    }

    if ( !$Param{Data}->{Collection} ) {
        return $Self->ReturnError(
            ErrorCode    => 'QueryEmbeddings.MissingParameter',
            ErrorMessage => "QueryEmbeddings: Collection is required!",
        );
    }

    my $LinkType = $Param{Data}->{LinkType} || 'Normal';

    if (
        !$Param{Data}->{UserLogin}
        && !$Param{Data}->{SessionID}
        )
    {
        return $Self->ReturnError(
            ErrorCode    => 'QueryEmbeddings.MissingParameter',
            ErrorMessage => "QueryEmbeddings: UserLogin or SessionID is required!",
        );
    }

    if ( $Param{Data}->{UserLogin} ) {
        if ( !$Param{Data}->{Password} ) {
            return $Self->ReturnError(
                ErrorCode    => 'QueryEmbeddings.MissingParameter',
                ErrorMessage => "QueryEmbeddings: Password or SessionID is required!",
            );
        }
    }

    # authenticate user
    my ( $UserID, $UserType ) = $Self->Auth(
        %Param,
    );

    if ( !$UserID ) {
        return $Self->ReturnError(
            ErrorCode    => 'QueryEmbeddings.AuthFail',
            ErrorMessage => "QueryEmbeddings: User could not be authenticated!",
        );
    }

    # get ticket object
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');

    # check TicketID
    my $TicketID;
    if ( $Param{Data}->{TicketNumber} ) {
        $TicketID = $TicketObject->TicketIDLookup(
            TicketNumber => $Param{Data}->{TicketNumber},
            UserID       => $UserID,
        );

    }
    else {
        $TicketID = $Param{Data}->{TicketID};
    }

    if ( !($TicketID) ) {
        return $Self->ReturnError(
            ErrorCode    => 'QueryEmbeddings.AccessDenied',
            ErrorMessage => "QueryEmbeddings: User does not have access to the ticket!",
        );
    }

    my %TicketData = $TicketObject->TicketGet(
        TicketID      => $TicketID,
        DynamicFields => 0,
        UserID        => $UserID,
    );

    if ( !IsHashRefWithData( \%TicketData ) ) {
        return $Self->ReturnError(
            ErrorCode    => 'QueryEmbeddings.AccessDenied',
            ErrorMessage => "QueryEmbeddings: User does not have access to the ticket!",
        );
    }

    # check basic needed permissions
    my $Access = $Self->CheckAccessPermissions(
        TicketID => $TicketID,
        UserID   => $UserID,
        UserType => $UserType,
    );

    if ( !$Access ) {
        return $Self->ReturnError(
            ErrorCode    => 'QueryEmbeddings.AccessDenied',
            ErrorMessage => "QueryEmbeddings: User does not have access to the ticket!",
        );
    }

    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');

    if ( !$Param{Data}->{ArticleID} ) {

        my @Articles = $ArticleObject->ArticleList(
            TicketID   => $TicketID,
            SenderType => 'customer',
            OnlyLast   => 1,
        );
        if (@Articles) {
            $Param{Data}->{ArticleID} = $Articles[0]{ArticleID};
        }
        else {
            return $Self->ReturnError(
                ErrorCode    => 'QueryEmbeddings.AccessDenied',
                ErrorMessage => "QueryEmbeddings: need ArticleID!",
            );
        }
    }

    my $ArticleBackendObject = $ArticleObject->BackendForArticle(
        TicketID  => $TicketID,
        ArticleID => $Param{Data}->{ArticleID},
    );

    if ( !$ArticleBackendObject ) {
        return $Self->ReturnError(
            ErrorCode    => 'QueryEmbeddings.AccessDenied',
            ErrorMessage => "QueryEmbeddings: Article unavailable!",
        );
    }

    my %Article = $ArticleBackendObject->ArticleGet(
        TicketID  => $TicketID,
        ArticleID => $Param{Data}->{ArticleID},
    );

    my $Query = $Param{Data}->{Query} // ( ( $Article{Subject} // '' ) . '\n' . ( $Article{Body} // '' ) );

    my $ConfigObject      = $Kernel::OM->Get('Kernel::Config');
    my $QueueToRAGMapping = $ConfigObject->Get('OTOBOAI::QueueToRAGMapping') // {};
    my $RAG               = $QueueToRAGMapping->{ $TicketData{Queue} }       // $ConfigObject->Get('OTOBOAI::DefaultRAG');

    my $WebserviceObject = $Kernel::OM->Get('Kernel::System::GenericInterface::Webservice');
    my $AIWebservice     = $WebserviceObject->WebserviceGet(
        Name => 'OTOBO-AI',
    );

    if ( !$AIWebservice ) {

        return $Self->ReturnError(
            ErrorCode    => 'QueryEmbeddings.WebserviceUnavail',
            ErrorMessage => "QueryEmbeddings: Webservice Invoker not found!",
        );
    }

    my $WebserviceID = $AIWebservice->{ID};

    $Result = $Kernel::OM->Get('Kernel::GenericInterface::Requester')->Run(
        WebserviceID => $WebserviceID,
        Invoker      => 'QueryEmbeddings',
        Asynchronous => 0,
        Data         => {
            Collection => $Param{Data}->{Collection},
            Labels     => [$RAG],
            Fulltext   => $Param{Data}->{Fulltext},
            Limit      => $Param{Data}->{Limit},
            Query      => $Query,
        }
    );

    return $Result,;
}

1;
