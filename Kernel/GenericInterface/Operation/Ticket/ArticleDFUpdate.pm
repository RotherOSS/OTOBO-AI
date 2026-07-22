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

package Kernel::GenericInterface::Operation::Ticket::ArticleDFUpdate;

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

Kernel::GenericInterface::Operation::Ticket::ArticleDFUpdate - GenericInterface Article Dynamic Field Update

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

    $Self->{Config}    = $Kernel::OM->Get('Kernel::Config')->Get('GenericInterface::Operation::ArticleDFUpdate');
    $Self->{Operation} = $Param{Operation};

    return $Self;
}

=head2 Run()

perform UpdateArticleDynamicField Operation. This will return the updated TicketID and
the updated ArticleID.

    my $Result = $OperationObject->Run(
        Data => {
            UserLogin         => 'some agent login',                            # UserLogin or CustomerUserLogin or SessionID is
                                                                                #   required
            SessionID         => 123,

            Password  => 'some password',                                       # if UserLogin or customerUserLogin is sent then
                                                                                #   Password is required

            TicketID     => 123,                                                # TicketID or TicketNumber is required
            TicketNumber => '2004040510440485',

            ArticleID    => 123,                                                # optional, otherwise last customer article id is used
            DynamicField =>
                {
                    Name   => 'some name',
                    Value  => $Value,                                          # value type depends on the dynamic field
                },
                # ...
            ],
        },
    );

    $Result = {
        Success         => 1,                       # 0 or 1
        ErrorMessage    => '',                      # in case of error
        Data            => {                        # result data payload after Operation
            TicketID    => 123,                     # Ticket  ID number in OTOBO (help desk system)
            ArticleID   => 43,                      # Article ID number in OTOBO (help desk system)
        },
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
            ErrorCode    => 'ArticleDFUpdate.EmptyRequest',
            ErrorMessage => "ArticleDFUpdate: The request data is invalid!",
        );
    }

    if ( !$Param{Data}->{TicketID} && !$Param{Data}->{TicketNumber} ) {
        return $Self->ReturnError(
            ErrorCode    => 'ArticleDFUpdate.MissingParameter',
            ErrorMessage => "ArticleDFUpdate: TicketID or TicketNumber is required!",
        );
    }

    if (
        !$Param{Data}->{UserLogin}
        && !$Param{Data}->{SessionID}
        )
    {
        return $Self->ReturnError(
            ErrorCode    => 'ArticleDFUpdate.MissingParameter',
            ErrorMessage => "ArticleDFUpdate: UserLogin or SessionID is required!",
        );
    }

    if ( $Param{Data}->{UserLogin} ) {
        if ( !$Param{Data}->{Password} ) {
            return $Self->ReturnError(
                ErrorCode    => 'ArticleDFUpdate.MissingParameter',
                ErrorMessage => "ArticleDFUpdate: Password or SessionID is required!",
            );
        }
    }

    # authenticate user
    my ( $UserID, $UserType ) = $Self->Auth(
        %Param,
    );

    if ( !$UserID ) {
        return $Self->ReturnError(
            ErrorCode    => 'ArticleDFUpdate.AuthFail',
            ErrorMessage => "ArticleDFUpdate: User could not be authenticated!",
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
            ErrorCode    => 'ArticleDFUpdate.AccessDenied',
            ErrorMessage => "ArticleDFUpdate: User does not have access to the ticket!",
        );
    }

    my %TicketData = $TicketObject->TicketGet(
        TicketID      => $TicketID,
        DynamicFields => 0,
        UserID        => $UserID,
    );

    if ( !IsHashRefWithData( \%TicketData ) ) {
        return $Self->ReturnError(
            ErrorCode    => 'ArticleDFUpdate.AccessDenied',
            ErrorMessage => "ArticleDFUpdate: User does not have access to the ticket!",
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
            ErrorCode    => 'ArticleDFUpdate.AccessDenied',
            ErrorMessage => "ArticleDFUpdate: User does not have access to the ticket!",
        );
    }

    my $DynamicFields = $Param{Data}->{DynamicField};
    if ( !IsArrayRefWithData($DynamicFields) ) {

        if ( !IsHashRefWithData($DynamicFields) ) {
            return $Self->ReturnError(
                ErrorCode    => 'ArticleDFUpdate.MissingParameter',
                ErrorMessage => "ArticleDFUpdate: DynamicField Element is missing.",
            );
        }
        $DynamicFields = [$DynamicFields];
    }

    if ( !IsArrayRefWithData($DynamicFields) ) {

        return $Self->ReturnError(
            ErrorCode    => 'ArticleDFUpdate.MissingParameter',
            ErrorMessage => "ArticleDFUpdate: DynamicField Element is empty.",
        );
    }

    for my $DynamicField ( $DynamicFields->@* ) {

        if ( !IsHashRefWithData($DynamicField) ) {
            return $Self->ReturnError(
                ErrorCode    => 'ArticleDFUpdate.MissingParameter',
                ErrorMessage => "ArticleDFUpdate: DynamicField Element is missing.",
            );
        }

        if ( !$DynamicField->{Name} ) {
            return $Self->ReturnError(
                ErrorCode    => 'ArticleDFUpdate.MissingParameter',
                ErrorMessage => "ArticleDFUpdate: DynamicField Element is missing child key 'Name'.",
            );
        }

        if ( !$DynamicField->{Value} ) {
            return $Self->ReturnError(
                ErrorCode    => 'ArticleDFUpdate.MissingParameter',
                ErrorMessage => "ArticleDFUpdate: DynamicField Element is missing child key 'Value'.",
            );
        }
    }

    # do the DF update

    my $ArticleObject      = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $DynamicFieldObject = $Kernel::OM->Get('Kernel::System::DynamicField');
    my $BackendObject      = $Kernel::OM->Get('Kernel::System::DynamicField::Backend');

    my $ArticleID = $Param{Data}->{ArticleID};
    if ( !$ArticleID ) {

        my @Articles = $ArticleObject->ArticleList(
            TicketID   => $TicketID,
            SenderType => 'customer',
            OnlyLast   => 1,
        );
        if (@Articles) {
            $ArticleID = $Articles[0]{ArticleID};
        }
    }

    if ( !$ArticleID ) {

        return $Self->ReturnError(
            ErrorCode    => 'ArticleDFUpdate.NoCustomerArticle',
            ErrorMessage => 'This ticket does not have a customer article.',
        );
    }

    $Result = 1;

    DYNAMICFIELD:
    for my $DynamicField ( $DynamicFields->@* ) {

        my $DynamicFieldConfig = $DynamicFieldObject->DynamicFieldGet(
            Name => $DynamicField->{Name},
        );

        my $Success = $BackendObject->ValueSet(
            DynamicFieldConfig => $DynamicFieldConfig,       # complete config of the DynamicField
            ObjectID           => $ArticleID,                # ID of the current object that the field
                                                             # must be linked to, e. g. TicketID
            Value              => $DynamicField->{Value},    # Value to store, depends on backend type
            UserID             => $UserID,
            DoWrite            => 1,                         # specific to OTOBOAI DF
        );

        if ( !$Success ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Unable to set value '"
                    . $DynamicField->{Value}
                    . "' for DF "
                    . $DynamicField->{Name}
                    . " on ArticleID $ArticleID with TicketID $TicketID",
            );
        }

        $Result = $Success if $Result;
    }

    return {
        Success => $Result,
        Data    => {
            TicketID  => $TicketID,
            ArticleID => $ArticleID,
            Success   => 1,
        }
    };
}

1;
