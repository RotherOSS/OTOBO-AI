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

package Kernel::Output::HTML::TicketZoom::AISimilarTickets;

use v5.24;
use strict;
use warnings;
use namespace::autoclean;
use utf8;

use parent 'Kernel::Output::HTML::Base';

# core modules

# CPAN modules

# OTOBO modules
use Kernel::Language              qw(Translatable);
use Kernel::System::VariableCheck qw(IsHashRefWithData);

our $ObjectManagerDisabled = 1;

sub Run {
    my ( $Self, %Param ) = @_;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my $UserObject   = $Kernel::OM->Get('Kernel::System::User');

    my %Ticket    = $Param{Ticket}->%*;
    my %AclAction = $Param{AclAction}->%*;
    my $TicketID  = $Ticket{TicketID};
    my $ArticleID;

    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my @Articles      = $ArticleObject->ArticleList(
        TicketID  => $TicketID,
        OnlyFirst => 1,
    );
    if (@Articles) {
        $ArticleID = $Articles[0]{ArticleID};
    }
    return '' if !$ArticleID;

    my $ArticleBackendObject = $ArticleObject->BackendForArticle(
        TicketID  => $TicketID,
        ArticleID => $ArticleID,
    );

    my %Article = $ArticleBackendObject->ArticleGet(
        TicketID  => $TicketID,
        ArticleID => $ArticleID,
    );

    return '' if !$Article{Subject} && !$Article{Body};

    my $MoreLikeThis = ( $Article{Subject} // '' ) . "\n" . ( $Article{Body} // '' );

    # set display options
    $Param{WidgetTitle} = Translatable('Similar Tickets');

    # get zoom settings depending on ticket type
    $Self->{DisplaySettings} = $ConfigObject->Get("Ticket::Frontend::AgentTicketZoom");

    # similar search query via otobo-ai-rag Invoker
    my $QueueToRAGMapping = $ConfigObject->Get('OTOBOAI::QueueToRAGMapping') // {};
    my $RAG               = $QueueToRAGMapping->{ $Ticket{Queue} }       // $ConfigObject->Get('OTOBOAI::DefaultRAG');

    my $WebserviceObject = $Kernel::OM->Get('Kernel::System::GenericInterface::Webservice');
    my $AIWebservice     = $WebserviceObject->WebserviceGet(
        Name => 'OTOBO-AI',
    );

    if ( !$AIWebservice ) {

        return '';
    }

    my $WebserviceID = $AIWebservice->{ID};

    my $TicketPairs = $Kernel::OM->Get('Kernel::GenericInterface::Requester')->Run(
        WebserviceID => $WebserviceID,
        Invoker      => 'QueryEmbeddings',
        Asynchronous => 0,
        Data         => {
            Collection => 'ticket_pairs',
            Labels     => [$RAG],
            Fulltext   => 0,
            Limit      => 5,
            Query      => $MoreLikeThis,
        }
    );

    my $TicketChunks = $Kernel::OM->Get('Kernel::GenericInterface::Requester')->Run(
        WebserviceID => $WebserviceID,
        Invoker      => 'QueryEmbeddings',
        Asynchronous => 0,
        Data         => {
            Collection => 'ticket_chunks',
            Labels     => [$RAG],
            Fulltext   => 0,
            Limit      => 5,
            Query      => $MoreLikeThis,
        }
    );

    my %Tickets;

    for my $Item ( $TicketPairs->{Data}->@* ) {

        my $ItemTicketID = $Item->{metadata}->{source_id};

        if( $ItemTicketID ne $TicketID ) {

            $Tickets{$ItemTicketID} = $Item;
        }
    }

    for my $Item ( $TicketChunks->{Data}->@* ) {

        my $ItemTicketID = $Item->{metadata}->{source_id};

        if( $ItemTicketID ne $TicketID ) {
            $Tickets{$ItemTicketID} = $Item;
        }
    }

    my @Data = values %Tickets;

    return '' if scalar @Data == 0;

    # render the widget
    $LayoutObject->Block(
        Name => 'SimilarTickets',
        Data => \@Data,
    );

    my $Output = $LayoutObject->Output(
        TemplateFile => 'AgentTicketZoom/AISimilarTickets',
        Data         => { %Param, %Ticket, %AclAction },
    );

    return {
        Output => $Output,
    };
}

1;
