# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
# Copyright (C) 2019-2025 Rother OSS GmbH, https://otobo.io/
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

package Kernel::System::OtoboAI;

use strict;
use warnings;

# core modules

# CPAN modules

# OTOBO modules

use parent qw(Kernel::System::AsynchronousExecutor);

our @ObjectDependencies = (
    'Kernel::System::Cache',
    'Kernel::System::Log',
    'Kernel::System::Main',
    'Kernel::GenericInterface::Requester',
    'Kernel::System::GenericInterface::Webservice',
    'Kernel::System::Ticket::Article',
);

sub new {

    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {%Param};
    bless( $Self, $Type );

    $Self->{CachePrefix} = 'AIAnswer';
    $Self->{CacheType}   = 'AIAnswer';
    $Self->{CacheTTL}    = 60 * 60 * 24 * 20;

    return $Self;
}

sub GetAnswerAsync {
    my ( $Self, %Param ) = @_;

    if ( !$Param{ObjectID} && !$Param{Question} ) {

        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Need either ObjectID or Question param.",
        );
        return;
    }

    $Kernel::OM->Get('Kernel::System::Log')->Log(
        Priority => 'debug',
        Message  => "OtoboAI::GetAnswerAsync call initiated.",
    );

    my $Success = $Self->AsyncCall(
        ObjectName               => 'Kernel::System::OtoboAI',    # optional, if not given the object is used from where
                                                                  # this function was called
        FunctionName             => 'GetAnswer',                  # the name of the function to execute
        FunctionParams           => \%Param,                      # a ref with the required parameters for the function
        Attempts                 => 1,                            # optional, default: 1, number of tries to lock the
                                                                  #   task by the scheduler
        MaximumParallelInstances => 0,                            # optional, default: 0 (unlimited), number of same
                                                                  #   function calls from the same object that can be
                                                                  #   executed at the same time
    );

    if ( !$Success ) {

        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Initialize async call failed!",
        );
        return;
    }

    return 1;
}

sub GetAnswer {
    my ( $Self, %Param ) = @_;

    if ( !$Param{ObjectID} && !$Param{Question} ) {

        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Need either ObjectID or Question param.",
        );
        return;
    }

    my $ErrorMessage = '';
    my $Success      = 0;

    # check whether otobo ai is enabled and if not, activate it
    my $WebserviceObject = $Kernel::OM->Get('Kernel::System::GenericInterface::Webservice');

    my $AIWebservice = $WebserviceObject->WebserviceGet(
        Name => 'OTOBO-AI',
    );

    if ( !$AIWebservice ) {

        $ErrorMessage = "OTOBO-AI webservice not found! Unable to continue.";
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => $ErrorMessage,
        );

        return {
            Success => $Success,
            Error   => $ErrorMessage,
        };
    }

    # Set the webservice id
    $Self->{WebserviceID} = $AIWebservice->{ID};

    # prepare the question
    my $ObjectID = $Param{ObjectID};
    my $Question;

    if ($ObjectID) {

        my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');

        my $ArticleID = $ObjectID;
        my $TicketID  = $ArticleObject->TicketIDLookup(
            ArticleID => $ArticleID,
        );

        my $ArticleBackendObject = $ArticleObject->BackendForArticle(
            TicketID  => $TicketID,
            ArticleID => $ArticleID,
        );

        my %Article = $ArticleBackendObject->ArticleGet(
            TicketID  => $TicketID,
            ArticleID => $ArticleID,
        );

        if ( !$Article{Body} ) {
            return {
                Success      => 0,
                ErrorMessage => "No body in the article!",
            };
        }

        $Question = $Article{Subject} . '. ' . $Article{Body};
    }
    else {

        $Question = $Param{Question};
    }

    my $Result = $Kernel::OM->Get('Kernel::GenericInterface::Requester')->Run(
        WebserviceID => $Self->{WebserviceID},
        Invoker      => 'GetAnswer',
        Asynchronous => 0,
        Data         => {
            Question => $Question,
        }
    );

    my $MainObject = $Kernel::OM->Get('Kernel::System::Main');
    my $Dump       = $MainObject->Dump($Result);

    $Kernel::OM->Get('Kernel::System::Log')->Log(
        Priority => 'debug',
        Message  => "OtoboAI GetAnswer Result: $Dump",
    );

    my $Answer = $Result->{Data}{Answer} || "";

    # set cache if ObjectID was given
    if ( $Param{ObjectID} ) {
        $Kernel::OM->Get('Kernel::System::Cache')->Set(
            Type  => $Self->{CacheType},
            TTL   => $Self->{CacheTTL},
            Key   => $Self->{CachePrefix} . $Param{ObjectID},
            Value => $Answer || "",
        );
    }

    return $Answer;
}

1;
