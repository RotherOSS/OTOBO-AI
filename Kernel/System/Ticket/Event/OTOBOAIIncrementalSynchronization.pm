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

    my $ImportObject = $Kernel::OM->Get('Kernel::System::OtoboAI::Import');

    if ( $Param{Data}{TicketID} ) {

        # reimport ticket
        $ImportObject->PurgeTickets(
            TicketID => $Param{Data}{TicketID}
        );
        $ImportObject->MigrateTickets(
            TicketID => $Param{Data}{TicketID}
        );
    }
    else {

        # reimport merge ticket
        $ImportObject->PurgeTickets(
            TicketID => $Param{Data}{MergeTicketID}
        );
        $ImportObject->MigrateTickets(
            TicketID => $Param{Data}{MergeTicketID}
        );

        # reimport main ticket
        $ImportObject->PurgeTickets(
            TicketID => $Param{Data}{MainTicketID}
        );
        $ImportObject->MigrateTickets(
            TicketID => $Param{Data}{MainTicketID}
        );
    }

    return 1;
}

1;
