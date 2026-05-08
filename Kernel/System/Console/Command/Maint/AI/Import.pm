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
use JSON;
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
    'Kernel::System::Ticket',
    'Kernel::System::Ticket::Article',
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

    if ( $Reference && -e $Reference ) {

        my $RefIDsJSON = file($Reference)->slurp;
        $Self->{RefIDs} = from_json($RefIDsJSON);
    }

    my $Targets = $Self->GetOption('target') || "tdf";

    if ( $Targets =~ /t/ ) {

        if ( $ReImport || $Purge ) {
            $Self->Purge( Collection => 'ticket_pairs' );
            $Self->Purge( Collection => 'ticket_chunks' );
        }

        if ( !$Purge ) {
            $Self->MigrateTickets(
                Sample    => $Sample,
                SampleNth => $SampleNth,
                Reference => $Reference,
            );
        }
    }

    if ( $Targets =~ /f/ ) {

        if ( $ReImport || $Purge ) {
            $Self->Purge( Collection => 'faqs' );
        }

        if ( !$Purge ) {
            $Self->MigrateFAQs();
        }
    }

    if ( $Targets =~ /d/ ) {

        if ( $ReImport || $Purge ) {
            $Self->Purge( Collection => 'docs' );
        }

        if ( !$Purge ) {
            $Self->MigrateDocs();
        }
    }

    return $Self->ExitCodeOk();
}

sub MigrateTickets {
    my ( $Self, %Param ) = @_;

    my $Sample    = $Param{Sample};
    my $SampleNth = $Param{SampleNth};
    my $Reference = $Param{Reference};

    my $TicketObject    = $Kernel::OM->Get('Kernel::System::Ticket');
    my $ArticleObject   = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $RequesterObject = $Kernel::OM->Get('Kernel::GenericInterface::Requester');

    my $BatchSize = 100;
    my @TicketIDs;

    my $OnlyVisibleForCustomer    = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::OnlyVisibleForCustomer') // 1;
    my $AllowedArticleSenderTypes = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::AllowedArticleSenderTypes');
    my $EnableUseCases            = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::EnableUseCases')             // 0;
    my $SearchRestrictionsHash    = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::Ticket::SearchRestrictions') // {};

    $Self->Print(
        "<green>Ingesting Tickets ...</green>\n"
    );

    my %TicketSample;

    for my $SearchRestrictionsKey ( keys $SearchRestrictionsHash->%* )
    {
        my $SearchRestrictions = dclone( $SearchRestrictionsHash->{$SearchRestrictionsKey} );
        my @UseCaseLabels      = ( delete $SearchRestrictions->{Label} )->@*;
        my $UseCaseLabel       = join ' ', @UseCaseLabels;

        if ( !exists $TicketSample{$UseCaseLabel} ) {
            $TicketSample{$UseCaseLabel} = [];
        }

        $Self->Print(
            "<yellow>Use Case: $UseCaseLabel.</yellow>\n"
        );

        # remove search parameters with empty arrays as they prevent search results entirely
        for my $ArrayParam (qw(Queues Services StateTypes Types)) {
            if ( !IsArrayRefWithData( $SearchRestrictions->{$ArrayParam} ) ) {
                delete $SearchRestrictions->{$ArrayParam};
            }
        }

        @TicketIDs = $TicketObject->TicketSearch(
            Result     => 'ARRAY',
            Limit      => 100_000_000,
            UserID     => 1,
            Permission => 'ro',
            %{$SearchRestrictions},
        );

        my $Errors    = 0;
        my $Count     = 0;
        my $Imported  = 0;
        my $Handled   = 0;
        my $Percent10 = ( sort { $a <=> $b } ( 10, int( $#TicketIDs / 10 ) ) )[1];
        my $Percent1  = ( sort { $a <=> $b } ( 1,  int( $#TicketIDs / 100 ) ) )[1];

        $Self->Print(
            "<yellow>" . ( scalar @TicketIDs ) . " Tickets are considered for transfer. This can take several hours, depending on the number of tickets.</yellow>\n"
        );

        BATCH:
        while ( $Count < scalar @TicketIDs ) {
            my $Until = $Count + $BatchSize - 1;
            if ( $Until > $#TicketIDs ) {
                $Until = $#TicketIDs;
            }
            my @Batch = @TicketIDs[ $Count .. $Until ];

            my @ImportTicketsQA;
            my @ImportTicketsAgentArticles;

            TICKETID:
            for my $TicketID (@Batch) {

                # show progress
                if ( ++$Count % $Percent10 == 0 ) {
                    my $Percent = int( $Count / ( $#TicketIDs / 100 ) );
                    $Self->Print(
                        "<yellow>$Count</yellow> of <yellow>$#TicketIDs</yellow> processed (<yellow>$Percent %</yellow> done. $Handled Tickets handled, $Imported Tickets imported).\n"
                    );
                }
                elsif ( $#TicketIDs > 50 && $Count % $Percent1 == 0 ) {
                    $Self->Print('. ');
                    select()->flush();    # show the dot immediately
                }

                my @Articles = $ArticleObject->ArticleList(
                    TicketID => $TicketID,
                );

                if ($Reference) {

                    my $IsPartOfSample = grep { $_ eq "$TicketID" } $Self->{RefIDs}->{$UseCaseLabel}->@*;
                    next TICKETID if ($IsPartOfSample);
                }

                next TICKETID if !@Articles;

                my %SenderLookup = map { $_ => $ArticleObject->ArticleSenderTypeLookup( SenderType => $_ ) } qw/agent customer/;

                # SelectionRule: only consider tickets started by a customer
                next TICKETID if $Articles[0]{SenderTypeID} ne $SenderLookup{customer};

                my $QuestionArticle = shift @Articles;
                my @AnswerArticles;

                if ($Sample) {

                    # keep 10% sample of tickets for testing and do NOT import them

                    if ( $Handled % $SampleNth == 0 ) {

                        $Handled++;
                        push $TicketSample{$UseCaseLabel}->@*, $TicketID;
                        next TICKETID;
                    }
                }

                ARTICLE:
                for my $Article (@Articles) {

                    # SelectionRule: skip tickets where the customer sent info twice without any agent interference
                    next TICKETID if $Article->{SenderTypeID} eq $SenderLookup{customer} && !@AnswerArticles;

                    # SelectionRule: skip articles if they are not customer visible
                    if ($OnlyVisibleForCustomer) {
                        next ARTICLE if $Article->{IsVisibleForCustomer} ne 1;
                    }

                    # SelectionRule: skip articles if their sendertype is not on the whitelist (if enabled)
                    if ($AllowedArticleSenderTypes) {
                        my $Allowed = 0;
                        TYPES:
                        for my $Type ( $AllowedArticleSenderTypes->@* ) {
                            if ( $SenderLookup{$Type} == $Article->{SenderTypeID} ) {
                                $Allowed = 1;
                                last TYPES;
                            }
                        }
                        if ( !$Allowed ) {
                            next ARTICLE;
                        }
                    }

                    push @AnswerArticles, $Article;
                }

                next TICKETID if !@AnswerArticles;

                {
                    my $ArticleBackend = $ArticleObject->BackendForArticle(
                        TicketID  => $TicketID,
                        ArticleID => $QuestionArticle->{ArticleID},
                    );

                    my %Article = $ArticleBackend->ArticleGet(
                        TicketID  => $TicketID,
                        ArticleID => $QuestionArticle->{ArticleID},
                    );

                    next TICKETID if !$Article{Body};

                    $QuestionArticle = \%Article;
                }

                my @AnswerArticlesWithBody;

                ANSWER:
                for my $i ( 0 .. $#AnswerArticles ) {
                    my $ArticleBackend = $ArticleObject->BackendForArticle(
                        TicketID  => $TicketID,
                        ArticleID => $AnswerArticles[$i]{ArticleID},
                    );

                    my %Article = $ArticleBackend->ArticleGet(
                        TicketID  => $TicketID,
                        ArticleID => $AnswerArticles[$i]{ArticleID},
                    );

                    next ANSWER if !$Article{Body};

                    # SelectionRule: Remove citations from agent articles
                    $Article{Body} =~ s/^\s*>.+?$//msg;

                    push @AnswerArticlesWithBody, \%Article;
                }

                next TICKETID if !@AnswerArticlesWithBody;

                $Handled++;
                $Imported++;

                my $QuestionSubject = $QuestionArticle->{Subject}         // '';
                my $QuestionBody    = $QuestionArticle->{Body}            // '';
                my $AnswerSubject   = $AnswerArticlesWithBody[0]{Subject} // '';
                my $AnswerBody      = $AnswerArticlesWithBody[0]{Body};

                $QuestionBody = $Self->StripSignature( Body => $QuestionBody );
                $AnswerBody   = $Self->StripSignature( Body => $AnswerBody );

                my $ImportQATicket = {
                    "source_id"     => $TicketID,
                    "content_items" => [
                        {
                            type => 'question',
                            text => $QuestionSubject . '. ' . $QuestionBody,
                        },
                        {
                            type => 'answer',
                            text => $AnswerSubject . '. ' . $AnswerBody,
                        },
                    ]
                };

                if ($EnableUseCases) {
                    $ImportQATicket->{labels} = \@UseCaseLabels;
                }

                push @ImportTicketsQA, $ImportQATicket;

                my @ContentItems;
                for my $AnswerArticleWithBody (@AnswerArticlesWithBody) {

                    my $Subject = $AnswerArticleWithBody->{Subject} // '';
                    my $Body    = $AnswerArticleWithBody->{Body}    // '';

                    $Body = $Self->StripSignature( Body => $Body );
                    push @ContentItems, {
                        type => 'text',
                        text => $Subject . '. ' . $Body,
                    };
                }

                my $ImportAgentArticles = {
                    "source_id"     => $TicketID,
                    "content_items" => \@ContentItems,
                };

                if ($EnableUseCases) {
                    $ImportAgentArticles->{labels} = \@UseCaseLabels;
                }

                push @ImportTicketsAgentArticles, $ImportAgentArticles;
            }

            my $Result;
            if (@ImportTicketsQA) {

                # Ingest Q/A articles
                $Result = $RequesterObject->Run(
                    WebserviceID => $Self->{WebserviceID},
                    Invoker      => 'IngestMany',
                    Asynchronous => 0,
                    Data         => {
                        Type    => 'ticket_pairs',      # currently supported: faq, documentation, ticket_pairs, ticket_chunks
                        Content => \@ImportTicketsQA,
                    },
                );

                if ( !$Result->{Success} ) {
                    $Errors++;
                    $Self->Print(
                        "<red>Error importing Tickets: " . $Result->{ErrorMessage} . "</red>\n"
                    );
                }
            }

            if (@ImportTicketsAgentArticles) {

                # Ingest agent articles
                $Result = $RequesterObject->Run(
                    WebserviceID => $Self->{WebserviceID},
                    Invoker      => 'IngestMany',
                    Asynchronous => 0,
                    Data         => {
                        Type    => 'ticket_chunks',
                        Content => \@ImportTicketsAgentArticles,
                    },
                );

                if ( !$Result->{Success} ) {
                    $Errors++;
                    $Self->Print(
                        "<red>Error importing Tickets: " . $Result->{ErrorMessage} . "</red>\n"
                    );
                }
            }
        }

        if ($Errors) {
            $Self->Print("<yellow>Ticket transfer complete. $Errors error(s) occurred!</yellow>\n");
        }
        else {
            $Self->Print("<green>Ticket transfer complete. Considered $Count tickets, of wich $Imported where imported.</green>\n");
        }
    }

    if ($Sample) {

        my $JSON = encode_json( \%TicketSample );
        file( $Self->{SamplePath} )->spew($JSON);
    }

    return 1;
}

sub MigrateFAQs {
    my ( $Self, %Param ) = @_;

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

    for my $SearchRestrictionsKey ( keys $SearchRestrictionsHash->%* )
    {
        my $SearchRestrictions = dclone( $SearchRestrictionsHash->{$SearchRestrictionsKey} );
        my @UseCaseLabels      = ( delete $SearchRestrictions->{Label} )->@*;

        $Self->Print(
            "<yellow>Use Case: " . ( join ' ', @UseCaseLabels ) . "</yellow>\n"
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

    $Self->Print(
        "<green>Ingesting Documents ...</green>\n"
    );

    # prepare the import
    my $RequesterObject = $Kernel::OM->Get('Kernel::GenericInterface::Requester');

    # determine search restrictions for document search
    my $SearchRestrictionsHash = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::Document::SearchRestrictions') // {};
    my $EnableUseCases         = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::EnableUseCases')               // 0;

    for my $SearchRestrictionsKey ( keys $SearchRestrictionsHash->%* )
    {
        my $SearchRestrictions = dclone( $SearchRestrictionsHash->{$SearchRestrictionsKey} );
        my @UseCaseLabels      = ( delete $SearchRestrictions->{Label} )->@*;

        $Self->Print(
            "<yellow>Use Case: " . ( join ' ', @UseCaseLabels ) . "</yellow>\n"
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
