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

package Kernel::System::Ticket::Event::OTOBOAIIncrementalSynchronization;

use strict;
use warnings;

our @ObjectDependencies = (
    'Kernel::System::Log',
    'Kernel::System::Ticket',
    'Kernel::System::OtoboAI::Import'
);

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Needed (qw(Event Data)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed!",
            );
            return;
        }
    }

    # check needed param in data
    if ( !$Param{Data}{TicketID} && ( !$Param{Data}{MergeTicketID} || !$Param{Data}{MainTicketID} ) ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Need TicketID(s) in Data!",
        );
        return;
    }

    # only execute this handler once for each web request, as multiple events may be
    # fired per one user action, for example ArticleCreate and TicketCustomerUpdate
    my $CacheKey = '_OTOBOAIIncrementalSynchronization::AlreadyProcessed';

    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my $ImportObject = $Kernel::OM->Get('Kernel::System::OtoboAI::Import');

    if ( $Param{Data}{TicketID} ) {

        return if ( $TicketObject->{$CacheKey}->{ $Param{Data}{TicketID} } );

        # reimport ticket
        $ImportObject->PurgeTickets(
            TicketID => $Param{Data}{TicketID}
        );
        $ImportObject->MigrateTicketsAsync(
            TicketID => $Param{Data}{TicketID}
        );

        # store information that ticket was processed on ticketobject
        $TicketObject->{$CacheKey}->{ $Param{Data}{TicketID} } = 1;
    }
    else {

        return
            if (
                $TicketObject->{$CacheKey}->{ $Param{Data}{MergeTicketID} }
                && $TicketObject->{$CacheKey}->{ $Param{Data}{MainTicketID} }
            );

        # reimport merge ticket
        $ImportObject->PurgeTickets(
            TicketID => $Param{Data}{MergeTicketID}
        );
        $ImportObject->MigrateTicketsAsync(
            TicketID => $Param{Data}{MergeTicketID}
        );

        # reimport main ticket
        $ImportObject->PurgeTickets(
            TicketID => $Param{Data}{MainTicketID}
        );
        $ImportObject->MigrateTicketsAsync(
            TicketID => $Param{Data}{MainTicketID}
        );

        # store information that tickets were processed on ticketobject
        $TicketObject->{$CacheKey}->{ $Param{Data}{MergeTicketID} } = 1;
        $TicketObject->{$CacheKey}->{ $Param{Data}{MainTicketID} }  = 1;
    }

    return 1;
}

1;
