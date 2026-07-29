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

package Kernel::System::FAQ::Event::OTOBOAIIncrementalSynchronization;

use strict;
use warnings;

our @ObjectDependencies = (
    'Kernel::System::Log',
    'Kernel::System::FAQ',
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
    for my $IDName (qw(ItemID)) {
        if ( !$Param{Data}{$IDName} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $IDName in Data!",
            );
            return;
        }
    }

    # only execute this handler once for each web request, implementing the same transaction
    # functionality as for tickets, even though there are currently no optional event types for faqs
    my $CacheKey = '_OTOBOAIIncrementalSynchronization::AlreadyProcessed';

    my $FAQObject    = $Kernel::OM->Get('Kernel::System::FAQ');
    my $ImportObject = $Kernel::OM->Get('Kernel::System::OtoboAI::Import');

    return if ( $FAQObject->{$CacheKey}->{ $Param{Data}{ItemID} } );

    $ImportObject->PurgeFAQs(
        FAQID => $Param{Data}{ItemID}
    );
    $ImportObject->MigrateFAQs(
        FAQID => $Param{Data}{ItemID}
    );

    # store information that faq item was processed on faqobject
    $FAQObject->{$CacheKey}->{ $Param{Data}{ItemID} } = 1;

    return 1;
}

1;
