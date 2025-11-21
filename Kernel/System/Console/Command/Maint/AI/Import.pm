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

package Kernel::System::Console::Command::Maint::AI::Import;

use strict;
use warnings;

use Path::Class qw(file);
use File::Find  qw(find);
use LWP::UserAgent;
use HTTP::Request::Common qw{ POST };

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
            "Do a re-import, which means the AI vectorstore and fulltext postgres Dbs will be purged.",
        Required => 0,
        HasValue => 0,

        #        ValueRegex => qr/^[tfd]+$/smx,
    );

    return;
}

sub PreRun {
    my ( $Self, %Param ) = @_;

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

    my $ReImport = $Self->GetOption('reimport');

    if ($ReImport) {
        $Self->Purge();
    }

    my $Targets = $Self->GetOption('target') || "tdf";

    if ( $Targets =~ /t/ ) {
        $Self->MigrateTickets();
    }

    if ( $Targets =~ /f/ ) {
        $Self->MigrateFAQs();
    }

    if ( $Targets =~ /d/ ) {
        $Self->MigrateDocs();
    }

    return $Self->ExitCodeOk();
}

sub MigrateTickets {
    my ( $Self, %Param ) = @_;

    my $TicketObject    = $Kernel::OM->Get('Kernel::System::Ticket');
    my $ArticleObject   = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $RequesterObject = $Kernel::OM->Get('Kernel::GenericInterface::Requester');

    my $BatchSize = 100;
    my @TicketIDs;

    my $SearchRestrictions = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::Ticket::SearchRestrictions') // {};
    my $TicketRestrictions = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::Ticket::Chunks')             // {};

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

    my $Count     = 0;
    my $Percent10 = ( sort { $a <=> $b } ( 10, int( $#TicketIDs / 10 ) ) )[1];
    my $Percent1  = ( sort { $a <=> $b } ( 1,  int( $#TicketIDs / 100 ) ) )[1];

    if ( $#TicketIDs > 100 ) {
        $Self->Print(
            "<yellow>Tickets are transferred. This can take several hours, depending on the number of tickets.</yellow>\n"
        );
    }

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

            my @Articles = $ArticleObject->ArticleList(
                TicketID => $TicketID,
            );

            next TICKETID if !@Articles;

            my %SenderLookup = map { $_ => $ArticleObject->ArticleSenderTypeLookup( SenderType => $_ ) } qw/agent customer/;

            # SelectionRule: only consider tickets started by a customer
            next TICKETID if $Articles[0]{SenderTypeID} ne $SenderLookup{customer};

            my $QuestionArticle = shift @Articles;
            my @AnswerArticles;

            ARTICLE:
            for my $Article (@Articles) {

                # SelectionRule: skip tickets where the customer sent info twice without any agent interference
                next TICKETID if $Article->{SenderTypeID} eq $SenderLookup{customer} && !@AnswerArticles;

                # SelectionRule: skip articles if they are not written by an agent or are not customer visible
                if ( $TicketRestrictions->{OnlyAgentArticles} ) {
                    next ARTICLE if $Article->{SenderTypeID} ne $SenderLookup{agent};
                }

                if ( $TicketRestrictions->{OnlyVisibleForCustomer} ) {
                    next ARTICLE if $Article->{IsVisibleForCustomer} ne 1;
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

                $AnswerArticles[$i] = \%Article;
            }

            next TICKETID if !@AnswerArticles;

            push @ImportTicketsQA, [
                {
                    type => 'question',
                    text => $QuestionArticle->{Subject} . '. ' . $QuestionArticle->{Body},
                },
                {
                    type => 'answer',
                    text => $AnswerArticles[0]{Subject} . '. ' . $AnswerArticles[0]{Body},
                },
            ];

            push @ImportTicketsAgentArticles, [
                map {
                    {
                        type => 'text',
                        text => $_->{Subject} . '. ' . $_->{Body},
                    }
                } @AnswerArticles
            ];
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
        }

        # TODO: Could be beautified for batches
        for (@Batch) {

            # show progress and potentially sleep
            if ( ++$Count % $Percent10 == 0 ) {
                my $Percent = int( $Count / ( $#TicketIDs / 100 ) );
                $Self->Print(
                    "<yellow>$Count</yellow> of <yellow>$#TicketIDs</yellow> processed (<yellow>$Percent %</yellow> done).\n"
                );
            }
            elsif ( $#TicketIDs > 50 && $Count % $Percent1 == 0 ) {
                $Self->Print('. ');
                select()->flush();    # show the dot immediately
            }
        }
    }

    # TODO: Error handling
    #if ($Errors) {
    #    $Self->Print("<yellow>Ticket transfer complete. $Errors error(s) occurred!</yellow>\n");
    #}
    #else {
    $Self->Print("<green>Ticket transfer complete. Transferred $Count tickets.</green>\n");

    #}

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

    # prepare the import
    my $FAQObject       = $Kernel::OM->Get('Kernel::System::FAQ');
    my $RequesterObject = $Kernel::OM->Get('Kernel::GenericInterface::Requester');
    my $HTMLUtilsObject = $Kernel::OM->Get('Kernel::System::HTMLUtils');

    # determine search restrictions for FAQSearch
    my $SearchRestrictions = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::FAQ::SearchRestrictions') // {};

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
        my $Question = $HTMLUtilsObject->ToAscii( String => $FAQ{Title} )
            . ". " . $HTMLUtilsObject->ToAscii( String => $FAQ{Field1} )
            . ". " . $HTMLUtilsObject->ToAscii( String => $FAQ{Field2} );

        my $Answer = $HTMLUtilsObject->ToAscii( String => $FAQ{Field3} );

        # prepare data item for invoker
        push @FAQData, [
            {
                type => 'question',
                text => $Question,
            },
            {
                type => 'answer',
                text => $Answer,
            }
        ];

        # bacthes of 10 FAQs
        if ( $Count % 10 == 0 ) {

            # ingest
            $RequesterObject->Run(
                WebserviceID => $Self->{WebserviceID},
                Invoker      => 'IngestMany',
                Asynchronous => 0,
                Data         => {
                    Type    => 'faqs',
                    Content => \@FAQData,
                },
            );
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

        $RequesterObject->Run(
            WebserviceID => $Self->{WebserviceID},
            Invoker      => 'IngestMany',
            Asynchronous => 0,
            Data         => {
                Type    => 'faqs',
                Content => \@FAQData,
            },
        );
    }

    if ($Errors) {
        $Self->Print("<yellow>FAQ transfer complete. $Errors error(s) occurred!</yellow>\n");
    }
    else {
        $Self->Print("<green>FAQ transfer complete. Transferred $Count FAQ items.</green>\n");
    }

    return 1;
}

sub MigrateDocs {
    my ( $Self, %Param ) = @_;

    # prepare the import
    my $RequesterObject = $Kernel::OM->Get('Kernel::GenericInterface::Requester');

    # determine search restrictions for document search
    my $SearchRestrictions = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::Document::SearchRestrictions') // {};

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
        my $FileContent = file($DocumentPath)->slurp();

        push @Content, [
            {

                type => 'text',
                text => $FileContent,
            }
        ];

        # ingest in batches of 10
        if ( $Count % 10 ) {

            # ingest
            $RequesterObject->Run(
                WebserviceID => $Self->{WebserviceID},
                Invoker      => 'IngestMany',
                Asynchronous => 0,
                Data         => {
                    Type    => 'docs',
                    Content => \@Content,
                },
            );
            @Content = ();
        }
    }

    # ingest leftovers
    if ( scalar @Content ) {

        $RequesterObject->Run(
            WebserviceID => $Self->{WebserviceID},
            Invoker      => 'IngestMany',
            Asynchronous => 0,
            Data         => {
                Type    => 'docs',
                Content => \@Content,
            },
        );
    }

    if ($Errors) {
        $Self->Print("<yellow>Document transfer complete. $Errors error(s) occurred!</yellow>\n");
    }
    else {
        $Self->Print("<green>Document transfer complete. Transferred $Count Document items.</green>\n");
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
        Data         => {},
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

                    # last write time stamp
                    my ($WriteTime) = ( stat($_) )[9];

                    # if last write time is NewerThanDays
                    if ( ( time() - $WriteTime ) < ( $NewerThanDays * $SecondsPerDay ) ) {

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

1;
