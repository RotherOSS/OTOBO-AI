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

package Kernel::System::Console::Command::Maint::AI::Scoring;

use strict;
use warnings;

use Path::Class qw(file);
use File::Find  qw(find);
use LWP::UserAgent;
use File::Basename        qw(basename dirname);
use HTTP::Request::Common qw{ POST };
use JSON;

use Kernel::System::VariableCheck qw(:all);

use parent qw(Kernel::System::Console::BaseCommand);

## nofilter(TidyAll::Plugin::OTOBO::Perl::ForeachToFor)

# Inform the object manager about the hard dependencies.
# This module must be discarded when one of the hard dependencies has been discarded.
our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::GenericInterface::Requester',
    'Kernel::System::GenericInterface::Webservice',
    'Kernel::System::Ticket',
    'Kernel::System::Ticket::Article',
    'Kernel::System::OtoboAI',
);

sub Configure {
    my ( $Self, %Param ) = @_;

    $Self->{TicketSample} = [];

    $Self->Description('Do a quality evaluation and write the coring result into a file');
    $Self->AddOption(
        Name        => 'sample',
        Description =>
            "Specify wfile path to sample.json file with the TicketIDs to sample. This file can be produced by the 'Maint::AI::Import' console command using the --sample option.",
        Required   => 0,
        HasValue   => 1,
        ValueRegex => qr/.*/smx,
    );
    $Self->AddOption(
        Name        => 'result',
        Description =>
            "Specify the file path for the scoring output should be written to in CSV (tab separated) format.",
        Required   => 0,
        HasValue   => 1,
        ValueRegex => qr/.*/smx,
    );
    $Self->AddOption(
        Name        => 'verbose',
        Description =>
            "when scoring, report verbosely for each ticket processed.",
        Required => 0,
        HasValue => 0,

        #   ValueRegex => qr/0|1/smx,
    );
    $Self->AddOption(
        Name        => 'limit',
        Description =>
            "when scoring, max number of ticket ids to take from sample.",
        Required => 0,
        HasValue => 1,

        ValueRegex => qr/^[0-9]+$/smx,
    );

    return;
}

sub PreRun {
    my ( $Self, %Param ) = @_;

    my $Sample = $Self->GetOption('sample');
    if ($Sample) {

        if ( !-e $Sample ) {
            $Self->Print("<red>sample parameter needs a valid path to a sample.json file containing TicketIDs.</red>\n");
            die;
        }
    }

    return;
}

sub Run {
    my ( $Self, %Param ) = @_;

    # check whether the AI web service is enabled and if not, activate it
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

    my $Sample  = $Self->GetOption('sample');
    my $Output  = $Self->GetOption('result') || 10;
    my $Verbose = $Self->GetOption('verbose');
    my $Limit   = $Self->GetOption('limit');

    my $JSON            = file($Sample)->slurp();
    my $SampleTicketIDs = decode_json($JSON);

    $Self->DoScoring(
        SampleTicketIDs => $SampleTicketIDs,
        OutputFile      => $Output,
        Verbose         => $Verbose,
        Limit           => $Limit || scalar $SampleTicketIDs->@*,
    );

    return $Self->ExitCodeOk();
}

sub DoScoring {

    my ( $Self, %Param ) = @_;

    my $OtoboAIObject = $Kernel::OM->Get('Kernel::System::OtoboAI');
    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');

    my $OutputCSVFileHandle;
    my $SampleTicketIDs = $Param{SampleTicketIDs};
    my $Verbose         = $Param{Verbose};
    my $Limit           = $Param{Limit};

    ## no critic(OTOBO::ProhibitOpen InputOutput::RequireBriefOpen)
    open( $OutputCSVFileHandle, '>', $Param{OutputFile} ) || die("failed to open file '$Param{OutputFile}'");

    print $OutputCSVFileHandle "TicketID\tScore\r\n";

    my $TotalScore = 0.0;
    my $NumScores  = 0;
    my $SampleSize = scalar $SampleTicketIDs->@*;

    if ($Verbose) {
        $Self->Print("Sample Size: $SampleSize\n");
    }

    my $Count = 0;
    TICKETID:
    for my $TicketID ( $SampleTicketIDs->@* ) {

        last TICKETID if ( $Count >= $Limit );
        $Count++;

        my $ArticleID;
        my @Articles = $ArticleObject->ArticleList(
            TicketID   => $TicketID,
            SenderType => 'customer',
            OnlyFirst  => 1,
        );
        if (@Articles) {
            $ArticleID = $Articles[0]{ArticleID};
        }

        if ($ArticleID) {

            if ($Verbose) {

                $Self->Print("<yellow>-----------------------------------------------</yellow>\n");
                $Self->Print("TicketID: $TicketID\n");

                my $ArticleBackendObject = $ArticleObject->BackendForArticle(
                    TicketID  => $TicketID,
                    ArticleID => $ArticleID,
                );

                my %Article = $ArticleBackendObject->ArticleGet(
                    TicketID  => $TicketID,
                    ArticleID => $ArticleID,
                );

                $Self->Print( "Question: " . $Article{Subject} . "\r\n" . $Article{Body} . "\r\n" );
            }

            my $Result = $OtoboAIObject->GetAnswer(
                ObjectID => $ArticleID,
                Persist  => 0
            );

            if ( IsHashRefWithData($Result) && $Result->{Success} == 1 ) {
                if ($Verbose) {

                    $Self->Print( "Answer: " . $Result->{Data}->{Answer} . "\r\nScore: " . $Result->{Data}->{Score} . "\r\n" );
                }

                $TotalScore += $Result->{Data}->{Score};
                $NumScores++;

                my $Line = $TicketID . "\t" . $Result->{Data}->{Score};
                print $OutputCSVFileHandle "$Line\r\n";
            }
            else {
                $Self->Print( "<red>Error: " . $Result->{Error} . "</red>\n" );
            }
        }
    }

    close($OutputCSVFileHandle);

    my $Score = 0;
    if ( $NumScores > 0 ) {
        $Score = $TotalScore / $NumScores;
    }

    $Self->Print("<yellow>$NumScores Tickets out of $Count Ticket samples have been scored, and the overall score is: $Score</yellow>\n");

    return;
}

1;
