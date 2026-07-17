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

package Kernel::System::Console::Command::Maint::AI::Import;

use strict;
use warnings;

use Path::Class qw(file);
use File::Find  qw(find);
use LWP::UserAgent;
use File::Basename        qw(basename dirname);
use HTTP::Request::Common qw{ POST };
use Storable qw(dclone);

use Kernel::System::VariableCheck qw(:all);

use parent qw(Kernel::System::Console::BaseCommand);

## nofilter(TidyAll::Plugin::OTOBO::Perl::ForeachToFor)

# Inform the object manager about the hard dependencies.
# This module must be discarded when one of the hard dependencies has been discarded.
our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::GenericInterface::Requester',
    'Kernel::System::FAQ',
    'Kernel::System::GenericInterface::Webservice',
    'Kernel::System::HTMLUtils',
    'Kernel::System::Package',
    'Kernel::System::OtoboAI::Import',
);

sub Configure {
    my ( $Self, %Param ) = @_;

    $Self->Description('Import existing tickets and faq articles to the AI vector database.');
    $Self->AddOption(
        Name        => 'target',
        Description =>
            "Specify which objects will be migrated. t: Tickets; f: FAQ articles; d: documents. If not specified all sources will be handled.",
        Required   => 0,
        HasValue   => 1,
        ValueRegex => qr/^[tfd]+$/smx,
    );
    $Self->AddOption(
        Name        => 'reimport',
        Description =>
            "Do a re-import, which means the AI vectorstore and fulltext postgres DBs will be purged for the target collections.",
        Required => 0,
        HasValue => 0,
    );
    $Self->AddOption(
        Name        => 'purge',
        Description =>
            "purge target collections).",
        Required => 0,
        HasValue => 0,
    );
    $Self->AddOption(
        Name        => 'sample-nth',
        Description =>
            "Only relevant with --do-scoring, specifies the sample size. Take every nth num for sampling. Specifying 10 will take every tenth, resulting in a 10% sample size. Specify 5 to take every 5th which will give 20% Sampelsize. Specify 20 to take every 20th which will yield 5% sample size. The default is 10.",
        Required   => 0,
        HasValue   => 1,
        ValueRegex => qr/[0-9]+/smx,
    );
    $Self->AddOption(
        Name        => 'sample',
        Description =>
            "Specify a file path to write a sample.json file containing TicketIDs to sample. When specified, then severy sample-nth Ticket will not be imported, but added to the list of sample ids. The default for sample-nth is 10 to sample every 10th Ticket (10% sample size). Override with the --sample-nth parameter.",
        Required   => 0,
        HasValue   => 1,
        ValueRegex => qr/.*/smx,
    );
    $Self->AddOption(
        Name        => 'reference',
        Description =>
            "Specify a file path to an existing sample.json file containing TicketIDs to reference. When specified, no new sample will be generated, but all TicketIDs from the reference sample file will be hold back again for scoring.",
        Required   => 0,
        HasValue   => 1,
        ValueRegex => qr/.*/smx,
    );
    $Self->AddOption(
        Name        => 'use-case',
        Description =>
            "The use-case name(s) to ingest data for. If left empty, all use cases will be ingested.",
        Required   => 0,
        HasValue   => 1,
        ValueRegex => qr/.*/smx,
        Multiple   => 1,
    );

    return;
}

sub PreRun {
    my ( $Self, %Param ) = @_;

    my $Sample = $Self->GetOption('sample');
    if ($Sample) {

        my $FullPath = $Sample;

        if ( -d $Sample ) {
            $FullPath .= "/sample.json";
        }

        $Self->{SamplePath} = $FullPath;

        my $SampleDir = dirname($FullPath);
        if ( !-d $SampleDir ) {
            $Self->Print("<red>do-sample parameter needs a valid path to an output file, but parent path $SampleDir does not exist.</red>\n");
            die;
        }
    }

    my $StripSignatureRegEx = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::StripSignatureRegex');
    if ($StripSignatureRegEx) {

        my $Regex = qr/$StripSignatureRegEx/m;
        $Self->{StripSignatureRegEx} = $Regex;
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

    my $Sample    = $Self->GetOption('sample');
    my $Reference = $Self->GetOption('reference');
    my $SampleNth = $Self->GetOption('sample-nth') || 10;

    my $ReImport = $Self->GetOption('reimport');
    my $Purge    = $Self->GetOption('purge');
    my $UseCases = $Self->GetOption('use-case');

    my $Targets = $Self->GetOption('target') || "tdf";

    if ( $Targets =~ /t/ ) {

        my $ImportObject = $Kernel::OM->Get('Kernel::System::OtoboAI::Import');

        if ( $ReImport || $Purge ) {
            $ImportObject->PurgeTickets();
        }

        if ( !$Purge ) {
            $ImportObject->MigrateTickets(
                Sample    => $Sample,
                SampleNth => $SampleNth,
                Reference => $Reference,
                UseCases  => $UseCases,
                Console   => $Self,
            );
        }
    }

    if ( $Targets =~ /f/ ) {

        if ( $ReImport || $Purge ) {
            $Self->Purge( Collection => 'faqs' );
        }

        if ( !$Purge ) {
            $Self->MigrateFAQs( UseCases => $UseCases );
        }
    }

    if ( $Targets =~ /d/ ) {

        if ( $ReImport || $Purge ) {
            $Self->Purge( Collection => 'docs' );
        }

        if ( !$Purge ) {
            $Self->MigrateDocs( UseCases => $UseCases );
        }
    }

    return $Self->ExitCodeOk();
}

sub MigrateFAQs {
    my ( $Self, %Param ) = @_;

    my $UseCases = $Param{UseCases};

    # check whether FAQ package is installed
    my $PackageObject = $Kernel::OM->Get('Kernel::System::Package');
    my $IsInstalled   = $PackageObject->PackageIsInstalled(
        Name => 'FAQ',
    );
    if ( !$IsInstalled ) {
        $Self->Print("<yellow>Skipping FAQ articles (FAQ not installed)...</yellow>\n");

        return 1;
    }

    $Self->Print(
        "<green>Ingesting FAQs ...</green>\n"
    );

    # prepare the import
    my $FAQObject       = $Kernel::OM->Get('Kernel::System::FAQ');
    my $RequesterObject = $Kernel::OM->Get('Kernel::GenericInterface::Requester');
    my $HTMLUtilsObject = $Kernel::OM->Get('Kernel::System::HTMLUtils');
    my $EnableUseCases  = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::EnableUseCases') // 0;

    # determine search restrictions for FAQSearch
    my $SearchRestrictionsHash = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::FAQ::SearchRestrictions') // {};

    SEARCHRESTRICTION:
    for my $SearchRestrictionsKey ( keys $SearchRestrictionsHash->%* )
    {
        my $SearchRestrictions = dclone( $SearchRestrictionsHash->{$SearchRestrictionsKey} );
        my @UseCaseLabels      = ( delete $SearchRestrictions->{Label} )->@*;

        my $IncludeUseCase = 0;
        if ( $UseCases && scalar $UseCases->@* ) {

            $IncludeUseCase = grep { $_ eq $SearchRestrictionsKey } $UseCases->@*;
        }
        else {
            $IncludeUseCase = 1;
        }

        next SEARCHRESTRICTION if $IncludeUseCase == 0;

        $Self->Print(
            "<yellow>Use Case: $SearchRestrictionsKey</yellow>\n"
        );

        my @FAQIDs = $FAQObject->FAQSearch(
            Result     => 'ARRAY',
            Limit      => 100_000_000,
            UserID     => 1,
            Permission => 'ro',
            %{$SearchRestrictions},
        );

        # iterate over the faqs
        my $Count     = 0;
        my $Percent10 = ( sort { $a <=> $b } ( 10, int( $#FAQIDs / 10 ) ) )[1];
        my $Percent1  = ( sort { $a <=> $b } ( 1,  int( $#FAQIDs / 100 ) ) )[1];

        if ( $#FAQIDs > 100 ) {
            $Self->Print(
                "<yellow>FAQ article are transferred. This can take several hours, depending on the number of faq article.</yellow>\n"
            );
        }

        my $Errors = 0;
        my @FAQData;

        FAQID:
        for my $FAQID (@FAQIDs) {

            $Count++;

            my %FAQ = $FAQObject->FAQGet(
                ItemID        => $FAQID,
                ItemFields    => 1,        # Optional, default 0. To include the item field content for this
                                           # FAQ item on the return structure.
                DynamicFields => 0,        # Optional, default 0. To include the dynamic fields for this
                                           # FAQ item on the return structure.
                UserID        => 1,
            );

            # scrub HTML
            my $Question = $HTMLUtilsObject->ToAscii( String => $FAQ{Title} // '' )
                . ". " . $HTMLUtilsObject->ToAscii( String => $FAQ{Field1} // '' )
                . ". " . $HTMLUtilsObject->ToAscii( String => $FAQ{Field2} // '' );

            my $Answer = $HTMLUtilsObject->ToAscii( String => $FAQ{Field3} // '' );

            # prepare data item for invoker

            my $Data = {
                "source_id"     => "$FAQID",
                "content_items" => [
                    {
                        type => 'question',
                        text => $Question,
                    },
                    {
                        type => 'answer',
                        text => $Answer,
                    }
                ]
            };

            if ($EnableUseCases) {
                $Data->{labels} = \@UseCaseLabels;
            }

            push @FAQData, $Data;

            # bacthes of 10 FAQs
            if ( $Count % 10 == 0 ) {

                # ingest
                my $Result = $RequesterObject->Run(
                    WebserviceID => $Self->{WebserviceID},
                    Invoker      => 'IngestMany',
                    Asynchronous => 0,
                    Data         => {
                        Type    => 'faqs',
                        Content => \@FAQData,
                    },
                );

                if ( !$Result->{Success} ) {
                    $Errors++;
                    $Self->Print(
                        "<red>Error importing FAQs: " . $Result->{ErrorMessage} . "</red>\n"
                    );
                }

                @FAQData = ();
            }

            # show progress and potentially sleep
            if ( $Count % $Percent10 == 0 ) {
                my $Percent = int( $Count / ( $#FAQIDs / 100 ) );
                $Self->Print(
                    "<yellow>$Count</yellow> of <yellow>$#FAQIDs</yellow> processed (<yellow>$Percent %</yellow> done).\n"
                );
            }
            elsif ( $#FAQIDs > 50 && $Count % $Percent1 == 0 ) {
                $Self->Print('. ');
                select()->flush();    # show the dot immediately
            }
        }

        # ingest leftovers
        if ( scalar @FAQData ) {

            my $Result = $RequesterObject->Run(
                WebserviceID => $Self->{WebserviceID},
                Invoker      => 'IngestMany',
                Asynchronous => 0,
                Data         => {
                    Type    => 'faqs',
                    Content => \@FAQData,
                },
            );

            if ( !$Result->{Success} ) {
                $Errors++;
                $Self->Print(
                    "<red>Error importing FAQs: " . $Result->{ErrorMessage} . "</red>\n"
                );
            }
        }

        if ($Errors) {
            $Self->Print("<yellow>FAQ transfer complete. $Errors error(s) occurred!</yellow>\n");
        }
        else {
            $Self->Print("<green>FAQ transfer complete. Transferred $Count FAQ items.</green>\n");
        }
    }
    return 1;
}

sub MigrateDocs {
    my ( $Self, %Param ) = @_;

    my $UseCases = $Param{UseCases};

    $Self->Print(
        "<green>Ingesting Documents ...</green>\n"
    );

    # prepare the import
    my $RequesterObject = $Kernel::OM->Get('Kernel::GenericInterface::Requester');

    # determine search restrictions for document search
    my $SearchRestrictionsHash = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::Document::SearchRestrictions') // {};
    my $EnableUseCases         = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::EnableUseCases')               // 0;

    SEARCHRESTRICTION:
    for my $SearchRestrictionsKey ( keys $SearchRestrictionsHash->%* )
    {
        my $SearchRestrictions = dclone( $SearchRestrictionsHash->{$SearchRestrictionsKey} );
        my @UseCaseLabels      = ( delete $SearchRestrictions->{Label} )->@*;

        my $IncludeUseCase = 0;
        if ( $UseCases && scalar $UseCases->@* ) {

            $IncludeUseCase = grep { $_ eq $SearchRestrictionsKey } $UseCases->@*;
        }
        else {
            $IncludeUseCase = 1;
        }

        next SEARCHRESTRICTION if $IncludeUseCase == 0;

        $Self->Print(
            "<yellow>Use Case: $SearchRestrictionsKey</yellow>\n"
        );

        my $DocumentPaths = $Self->_DocumentSearch(
            %$SearchRestrictions,
        );

        my @Content;
        my $Count = 0;
        my $Errors;

        DOCUMENT:
        foreach my $DocumentPath (@$DocumentPaths) {

            $Count++;

            # slurp content of file
            my $FileContent = file($DocumentPath)->slurp( iomode => '<:encoding(UTF-8)' ) // '';

            my $Data = {
                "source_id"     => $DocumentPath,
                "content_items" => [
                    {
                        type => 'text',
                        text => $FileContent,
                    }
                ]
            };

            if ($EnableUseCases) {
                $Data->{labels} = \@UseCaseLabels;
            }

            push @Content, $Data;

            # ingest in batches of 10
            if ( $Count % 10 ) {

                # ingest
                my $Result = $RequesterObject->Run(
                    WebserviceID => $Self->{WebserviceID},
                    Invoker      => 'IngestMany',
                    Asynchronous => 0,
                    Data         => {
                        Type    => 'docs',
                        Content => \@Content,
                    },
                );

                if ( !$Result->{Success} ) {
                    $Errors++;
                    $Self->Print(
                        "<red>Error importing Document '$DocumentPath' : " . $Result->{ErrorMessage} . "</red>\n"
                    );
                }

                @Content = ();
            }
        }

        # ingest leftovers
        if ( scalar @Content ) {

            my $Result = $RequesterObject->Run(
                WebserviceID => $Self->{WebserviceID},
                Invoker      => 'IngestMany',
                Asynchronous => 0,
                Data         => {
                    Type    => 'docs',
                    Content => \@Content,
                },
            );

            if ( !$Result->{Success} ) {
                $Errors++;
                $Self->Print(
                    "<red>Error importing Documents: " . $Result->{ErrorMessage} . "</red>\n"
                );
            }
        }

        if ($Errors) {
            $Self->Print("<yellow>Document transfer complete. $Errors error(s) occurred!</yellow>\n");
        }
        else {
            $Self->Print("<green>Document transfer complete. Transferred $Count Document items.</green>\n");
        }
    }
    return 1;
}

sub Purge {
    my ( $Self, %Param ) = @_;

    my $RequesterObject = $Kernel::OM->Get('Kernel::GenericInterface::Requester');

    my $Result = $RequesterObject->Run(
        WebserviceID => $Self->{WebserviceID},
        Invoker      => 'Purge',
        Asynchronous => 0,
        Data         => {
            Collection => $Param{Collection}
        },
    );

    return IsHashRefWithData($Result)        &&
        $Result->{Success}                   &&
        IsHashRefWithData( $Result->{Data} ) &&
        $Result->{Data}{success};
}

sub _DocumentSearch {

    my ( $Self, %Param ) = @_;

    my $DocumentRoot  = $Param{DocumentPath};
    my $NewerThanDays = $Param{NewerThanDays};

    if ( !-d $DocumentRoot ) {
        $Self->Print("<yellow>Skipping Documents (Document folder '$DocumentRoot' does not exist)...</yellow>\n");
        return;
    }

    my $SecondsPerDay = 60 * 60 * 24;

    # glob files recursively starting in $DocumentRoot
    my @Files;
    find(
        {
            wanted => sub {

                # only handle files, not directories
                if ( !-d $_ ) {

                    if ($NewerThanDays) {

                        # last write time stamp
                        my ($WriteTime) = ( stat($_) )[9];

                        # if last write time is NewerThanDays
                        if ( ( time() - $WriteTime ) < ( $NewerThanDays * $SecondsPerDay ) ) {

                            # add this file to result set
                            push @Files, $_;
                        }
                    }
                    else {
                        # add this file to result set
                        push @Files, $_;
                    }
                }
            },
            no_chdir => 1
        },
        $DocumentRoot
    );

    return \@Files;
}

sub StripSignature {

    my ( $Self, %Param ) = @_;

    my $Body = $Param{Body};

    my $RegEx = $Self->{StripSignatureRegEx};
    return $Body if ( !$RegEx );

    if ( $Body =~ /$RegEx/ ) {

        return substr( $Body, 0, $-[0] );
    }
    else {

        return $Body;
    }
}

1;
