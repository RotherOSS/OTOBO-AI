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

package Kernel::System::Console::Command::Maint::AI::GetAnswer;

use strict;
use warnings;

use Kernel::System::VariableCheck qw(:all);

use parent qw(Kernel::System::Console::BaseCommand);

## nofilter(TidyAll::Plugin::OTOBO::Perl::ForeachToFor)

# Inform the object manager about the hard dependencies.
# This module must be discarded when one of the hard dependencies has been discarded.
our @ObjectDependencies = (
    'Kernel::System::GenericInterface::Webservice',
    'Kernel::System::Main',
    'Kernel::System::OtoboAI',
    'Kernel::System::Ticket::Article',
);

sub Configure {
    my ( $Self, %Param ) = @_;

    $Self->Description('Retrieve an AI generated Answer from the otobo-ai-services container.');
    $Self->AddOption(
        Name        => 'article-id',
        Description => 'ArticleID',
        Required    => 0,
        HasValue    => 1,
        ValueRegex  => qr/^\d+$/smx,
    );
    $Self->AddOption(
        Name        => 'ticket-id',
        Description => 'TicketID',
        Required    => 0,
        HasValue    => 1,
        ValueRegex  => qr/^\d+$/smx,
    );
    $Self->AddOption(
        Name        => 'question',
        Description => 'Question',
        Required    => 0,
        HasValue    => 1,
        ValueRegex  => qr/^.+$/smx,
    );

    return;
}

sub PreRun {
    my ( $Self, %Param ) = @_;

    # check whether otobo-ai web service is enabled and if not, activate it
    my $WebserviceObject = $Kernel::OM->Get('Kernel::System::GenericInterface::Webservice');

    my $AIWebservice = $WebserviceObject->WebserviceGet(
        Name => 'OTOBO-AI',
    );

    if ( !$AIWebservice ) {
        $Self->Print("<red>OTOBO-AI webservice not found! Unable to continue.</red>\n");
        die;
    }

    # Set the webservice id
    $Self->{WebserviceID} = $AIWebservice->{ID};

    if ( $AIWebservice->{ValidID} != 1 ) {
        $Self->Print(
            "<yellow>OTOBO-AI webservice is now activated. If you don't want to keep it enabled, please disable it manually in the admin interface, after the import is complete.</yellow>\n"
        );
        my $Success = $WebserviceObject->WebserviceUpdate(
            %{$AIWebservice},
            ValidID => 1,
            UserID  => 1,
        );

        if ( !$Success ) {
            $Self->Print("<red>OTOBO-AI webservice could not be activated! Unable to continue.</red>\n");
            die;
        }
    }

    return;
}

sub Run {
    my ( $Self, %Param ) = @_;

    my $OtoboAIObject = $Kernel::OM->Get('Kernel::System::OtoboAI');
    my $Result;

    my $Question = $Self->GetOption('question');
    if ($Question) {

        $Result = $OtoboAIObject->GetAnswer(
            Question => $Question,
        );
    }
    else {

        my $TicketID  = $Self->GetOption('ticket-id');
        my $ArticleID = $Self->GetOption('article-id');

        if ( !$ArticleID ) {

            my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');
            my @Articles      = $ArticleObject->ArticleList(
                TicketID   => $TicketID,
                SenderType => 'customer',
                OnlyFirst  => 1,
            );
            if (@Articles) {
                $ArticleID = $Articles[0]{ArticleID};
            }

        }

        if ( !$ArticleID ) {

            $Self->Print("<red>Either Question or ArticleID or TicketID parameter is required.</red>\n");
            die;
        }

        $Result = $OtoboAIObject->GetAnswer(
            ObjectID => $ArticleID,
        );
    }

    my $MainObject = $Kernel::OM->Get('Kernel::System::Main');
    my $Dump       = $MainObject->Dump($Result);

    $Self->Print("$Dump\n");

    return $Self->ExitCodeOk();
}

1;
