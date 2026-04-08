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
        Name        => 'json',
        Description =>
            "when scoring, report verbosely for each ticket processed in the specified JSON file.",
        Required   => 0,
        HasValue   => 1,
        ValueRegex => qr/.*/smx,
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

    my $Sample     = $Self->GetOption('sample');
    my $Output     = $Self->GetOption('result') || 10;
    my $JSONOutput = $Self->GetOption('json');
    my $Limit      = $Self->GetOption('limit');

    my $JSON            = file($Sample)->slurp();
    my $SampleTicketIDs = decode_json($JSON);

    $Self->DoScoring(
        SampleTicketIDs => $SampleTicketIDs,
        OutputFile      => $Output,
        JSONOutput      => $JSONOutput,
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
    my $JSONOutput      = $Param{JSONOutput};
    my $Limit           = $Param{Limit};

    ## no critic(OTOBO::ProhibitOpen InputOutput::RequireBriefOpen)
    open( $OutputCSVFileHandle, '>', $Param{OutputFile} ) || die("failed to open file '$Param{OutputFile}'");

    my $JSONOutputFileHandle;
    if ($JSONOutput) {
        open( $JSONOutputFileHandle, '>', $Param{JSONOutput} ) || die("failed to open file '$Param{JSONOutput}'");
    }

    my $Firstline  = 1;
    my $NumScores  = 0;
    my $SampleSize = scalar $SampleTicketIDs->@*;

    my $VerboseJSON = {
        Data => [],
    };

    if ($JSONOutput) {
        $VerboseJSON->{SampleSize} = $SampleSize;
    }

    my $Count = 0;
    TICKETID:
    for my $TicketID ( $SampleTicketIDs->@* ) {

        my $VerboseJSONItem = {};

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

            $Self->Print("TicketID: $TicketID\n");

            if ($JSONOutput) {

                $VerboseJSONItem->{TicketID} = $TicketID;

                my $ArticleBackendObject = $ArticleObject->BackendForArticle(
                    TicketID  => $TicketID,
                    ArticleID => $ArticleID,
                );

                my %Article = $ArticleBackendObject->ArticleGet(
                    TicketID  => $TicketID,
                    ArticleID => $ArticleID,
                );

                $VerboseJSONItem->{Question} = $Article{Subject} . "\r\n" . $Article{Body};
            }

            my $Result = $OtoboAIObject->GetAnswer(
                ObjectID  => $ArticleID,
                Persist   => 0,
                DoScoring => 1,
            );

            if ( IsHashRefWithData($Result) && $Result->{Success} == 1 ) {
                if ($JSONOutput) {

                    $VerboseJSONItem->{Answer} = $Result->{Data}->{Answer};
                }

                $NumScores++;
                my @LineItems = (
                    $TicketID,
                );

                my $ScoreJSON = $Result->{Data}->{Score};
                my $Scores    = from_json($ScoreJSON);
                my $Reasoning = delete $Scores->{reasoning};

                if ($JSONOutput) {

                    $VerboseJSONItem->{Reasoning} = $Reasoning;
                }

                if ($Firstline) {

                    my @Keys = sort keys $Scores->%*;
                    my $Line = join ";", @Keys;

                    print $OutputCSVFileHandle "TicketID;$Line\r\n";
                    $Firstline = 0;
                }

                for my $Key ( sort keys $Scores->%* ) {

                    my $Score = $Scores->{$Key};

                    $Score =~ s/false/0/i;
                    $Score =~ s/true/1/i;

                    push @LineItems, $Score;

                    if ($JSONOutput) {

                        $VerboseJSONItem->{$Key} = $Score;
                    }
                }

                my $Line = join ";", @LineItems;

                print $OutputCSVFileHandle "$Line\r\n";

                push $VerboseJSON->{Data}->@*, $VerboseJSONItem;
            }
            else {
                $Self->Print( "<red>Error: " . $Result->{Error} . "</red>\n" );
            }
        }
    }

    close($OutputCSVFileHandle);

    if ($JSONOutput) {
        $VerboseJSON->{Scored} = $NumScores;
        print $JSONOutputFileHandle encode_json($VerboseJSON);
        close($JSONOutputFileHandle);
    }

    return;
}

1;
