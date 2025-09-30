# --
# Copyright (C) 2019-2020 Rother OSS GmbH, https://rother-oss.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --

package var::packagesetup::OTOBOAI;

use strict;
use warnings;

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::GenericInterface::Webservice',
    'Kernel::System::Log',
);

=head1 NAME

var::packagesetup::RotherOSSOTOBOAI - code to execute during package installation

=head1 SYNOPSIS

All functions

=head1 PUBLIC INTERFACE

=over 4

=cut

=item new()

create an object

    use Kernel::System::ObjectManager;
    local $Kernel::OM = Kernel::System::ObjectManager->new();
    my $CodeObject = $Kernel::OM->Get('var::packagesetup::FAQ');

=cut

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    # always discard the config object before package code is executed,
    # to make sure that the config object will be created newly, so that it
    # will use the recently written new config from the package
    $Kernel::OM->ObjectsDiscard(
        Objects => ['Kernel::Config'],
    );

    $Self->{Invoker} = {
        IngestMany => {
            Description => 'Import content to our roboto ai.',
            Events      => [
#                {
#                    Asynchronous => '0',
#                    Event        => 'TicketCreate',
#                },
            ],
            Type => 'OTOBOAI::IngestMany',
        },
        GetAnswer => {
            Description => 'Get an answer based on the ingested data.',
            Events      => [
            ],
            Type => 'OTOBOAI::GetAnswer',
        },
    };

    $Self->{InvokerControllerMapping} = {
        IngestMany => {
            Command    => 'PUT',
            Controller => '/otobo-ai/embedding/ingest-many',
        },
        GetAnswer => {
            Command    => 'POST',
            Controller => '/otobo-ai/tfd_rag1/invoke',
        },
    };

    return $Self;
}

=item CodeInstall()

run the code install part

    my $Result = $CodeObject->CodeInstall();

=cut

sub CodeInstall {
    my ( $Self, %Param ) = @_;

    my $WebserviceObject = $Kernel::OM->Get('Kernel::System::GenericInterface::Webservice');
    my $ID               = $WebserviceObject->WebserviceAdd(
        Name   => 'OTOBO-AI',
        Config => {

            # Webservice Config
            Debugger => {
                DebugThreshold => 'error',
                TestMode       => '0',
            },
            Description => '',
            Provider    => {
                Transport => {
                    Type => '',
                },
            },
            RemoteSystem => '',
            Requester    => {
                Invoker => $Self->{Invoker},
                Transport => {
                    Config => {
                        DefaultCommand           => 'POST',
                        Host                     => 'http://otobo-ai:8000',
                        InvokerControllerMapping => $Self->{InvokerControllerMapping},
                        Timeout => '30',
                    },
                    Type => 'HTTP::REST',
                },
            }

                # EO Webservice Config
        },
        ValidID => 1,
        UserID  => 1,
    );

    if ($ID) {
        return 1;
    }
    else {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Could not install the OTOBOAI webservice!",
        );
        return;
    }
}

=item CodeUpgrade()

run the code upgrade part

    my $Result = $CodeObject->CodeUpgrade();

=cut

sub CodeUpgrade {
    my ( $Self, %Param ) = @_;

    my $WebserviceObject = $Kernel::OM->Get('Kernel::System::GenericInterface::Webservice');
    my $Webservice = $WebserviceObject->WebserviceGet(
        Name => 'OTOBOAI',
    );

    if (!$Webservice) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Did not find the OTOBOAI webservice!",
        );
        return;
    }

    # upgrade webservice
    $Webservice->{Config}{Requester}{Invoker} = $Self->{Invoker};
    $Webservice->{Config}{Requester}{Transport}{InvokerControllerMapping} = $Self->{InvokerControllerMapping};


    my $Success = $WebserviceObject->WebserviceUpdate(
        %{ $Webservice },
        UserID  => 1,
    );

    if ( !$Success ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Could not update the OTOBOAI webservice!",
        );
        return;
    }
    return 1;
}

=item CodeUninstall()

run the code uninstall part

    my $Result = $CodeObject->CodeUninstall();

=cut

sub CodeUninstall {
    my ( $Self, %Param ) = @_;

    my $WebserviceObject = $Kernel::OM->Get('Kernel::System::GenericInterface::Webservice');

    my $Webservice = $WebserviceObject->WebserviceGet(
        Name => 'OTOBO-AI',
    );
    $WebserviceObject->WebserviceDelete(
        ID     => $Webservice->{ID},
        UserID => 1,
    );

    return 1;
}

1;

=back
