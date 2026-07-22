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

package var::packagesetup::OTOBOAI;

use strict;
use warnings;

# core modules

# CPAN modules

# OTOBO modules
use Kernel::System::VariableCheck qw(IsHashRefWithData);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::DynamicField',
    'Kernel::System::DynamicField::Backend',
    'Kernel::System::GenericInterface::Webservice',
    'Kernel::System::Log',
    'Kernel::System::Queue',
    'Kernel::System::StandardTemplate',
    'Kernel::System::Valid',
    'Kernel::System::SysConfig',
    'Kernel::System::Main',
);

=head1 NAME

var::packagesetup::OTOBOAI - code to execute during package installation

=head1 PUBLIC INTERFACE

=cut

=head2 new()

create an object

    use Kernel::System::ObjectManager;
    local $Kernel::OM = Kernel::System::ObjectManager->new();
    my $CodeObject = $Kernel::OM->Get('var::packagesetup::OTOBOAI');

=cut

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    # set dynamic field name here
    $Self->{DynamicFieldName} = 'OTOBOAI';

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
        Purge => {
            Description => 'Purge the otobo-ai vector store.',
            Events      => [
            ],
            Type => 'OTOBOAI::Purge',
        },
        DeleteByID => {
            Description => 'Purge a single item the otobo-ai vector store.',
            Events      => [
            ],
            Type => 'OTOBOAI::Purge',
        },
    };

    $Self->{InvokerControllerMapping} = {
        IngestMany => {
            Command    => 'PUT',
            Controller => '/otobo-ai/embedding/ingest-many',
        },
        GetAnswer => {
            Command    => 'POST',
            Controller => '/otobo-ai/:RAG/invoke',
        },
        Purge => {
            Command    => 'DELETE',
            Controller => '/otobo-ai/embedding/purge/:Collection',
        },
        DeleteByID => {
            Command    => 'POST',
            Controller => '/otobo-ai/embedding/delete',
        },
    };

    $Self->{Operation} = {

        ArticleDFUpdate => {
            Description       => 'ArticleDFUpdate',
            IncludeTicketData => '0',
            Type              => 'Ticket::ArticleDFUpdate'
        },
        TicketGet => {
            Description       => 'Retrieve a Ticket',
            IncludeTicketData => '0',
            Type              => 'Ticket::TicketGet',
        },
        TicketUpdate => {
            Description       => 'Update a Ticket',
            IncludeTicketData => '0',
            Type              => 'Ticket::TicketUpdate',
        }
    };

    $Self->{RouteOperationMapping} = {
        ArticleDFUpdate => {
            RequestMethod => ['PUT'],
            Route         => '/Ticket/:TicketID/Article/DF'
        },
        TicketGet => {
            RequestMethod => ['GET'],
            Route         => '/Ticket/:TicketID',
        },
        TicketUpdate => {
            RequestMethod => ['PUT'],
            Route         => '/Ticket/:TicketID',
        },
    };

    return $Self;
}

=head2 CodeInstall()

run the code install part

    my $Result = $CodeObject->CodeInstall();

=cut

sub CodeInstall {
    my ( $Self, %Param ) = @_;

    # create OTOBOAI dynamic field
    $Self->_CreateAIDynamicField();

    # create AI answer template
    $Self->_CreateAIAnswerTemplate();

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
                Operation => $Self->{Operation},
                Transport => {
                    Config => {
                        AdditionalHeaders     => undef,
                        KeepAlive             => '',
                        MaxLength             => '100000',
                        OutboundHeaders       => {},
                        RouteOperationMapping => $Self->{RouteOperationMapping},
                    },
                    Type => 'HTTP::REST',
                },
            },
            RemoteSystem => '',
            Requester    => {
                Invoker   => $Self->{Invoker},
                Transport => {
                    Config => {
                        DefaultCommand           => 'POST',
                        Host                     => 'http://otobo-ai:8000',
                        InvokerControllerMapping => $Self->{InvokerControllerMapping},
                        Timeout                  => '300',
                    },
                    Type => 'HTTP::REST',
                },
            }

            # EO Webservice Config
        },
        ValidID => 1,
        UserID  => 1,
    );

    if ( !$ID ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Could not install the OTOBOAI webservice!",
        );
        return;
    }

    $Self->_UpdateArticleActions( Channel => 'Email' );
    $Self->_UpdateArticleActions( Channel => 'Phone' );

    return 1;
}

=head2 CodeUpgrade()

run the code upgrade part

    my $Result = $CodeObject->CodeUpgrade();

=cut

sub CodeUpgrade {
    my ( $Self, %Param ) = @_;

    my $WebserviceObject = $Kernel::OM->Get('Kernel::System::GenericInterface::Webservice');
    my $Webservice       = $WebserviceObject->WebserviceGet(
        Name => 'OTOBO-AI',
    );

    if ( !$Webservice ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Did not find the OTOBOAI webservice!",
        );
        return;
    }

    # upgrade webservice
    $Webservice->{Config} = {

        # Webservice Config
        Debugger => {
            DebugThreshold => 'error',
            TestMode       => '0',
        },
        Description => '',
        Provider    => {
            Operation => $Self->{Operation},
            Transport => {
                Config => {
                    AdditionalHeaders     => undef,
                    KeepAlive             => '',
                    MaxLength             => '100000',
                    OutboundHeaders       => {},
                    RouteOperationMapping => $Self->{RouteOperationMapping},
                },
                Type => 'HTTP::REST',
            },
        },
        RemoteSystem => '',
        Requester    => {
            Invoker   => $Self->{Invoker},
            Transport => {
                Config => {
                    DefaultCommand           => 'POST',
                    Host                     => 'http://otobo-ai:8000',
                    InvokerControllerMapping => $Self->{InvokerControllerMapping},
                    Timeout                  => '300',
                },
                Type => 'HTTP::REST',
            },
        }

        # EO Webservice Config
    };

    my $Success = $WebserviceObject->WebserviceUpdate(
        %{$Webservice},
        UserID => 1,
    );

    if ( !$Success ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Could not update the OTOBOAI webservice!",
        );
        return;
    }

    $Self->_UpdateArticleActions( Channel => 'Email' );
    $Self->_UpdateArticleActions( Channel => 'Phone' );

    return 1;
}

=head2 CodeUninstall()

run the code uninstall part

    my $Result = $CodeObject->CodeUninstall();

=cut

sub CodeUninstall {
    my ( $Self, %Param ) = @_;

    $Self->_CleanupArticleActions( Channel => 'Phone' );
    $Self->_CleanupArticleActions( Channel => 'Email' );

    my $WebserviceObject = $Kernel::OM->Get('Kernel::System::GenericInterface::Webservice');

    my $Webservice = $WebserviceObject->WebserviceGet(
        Name => 'OTOBO-AI',
    );
    $WebserviceObject->WebserviceDelete(
        ID     => $Webservice->{ID},
        UserID => 1,
    );

    # delete OTOBOAI dynamic field
    $Self->_DeleteAIDynamicField();

    # delete Answer template
    $Self->_DeleteAIAnswerTemplate();

    return 1;
}

=head2 _CreateAIDynamicField()

creates the dynamic field needed for the AI response functionality

    my $Result = $CodeObject->_CreateAIDynamicField();

=cut

sub _CreateAIDynamicField {
    my ( $Self, %Param ) = @_;

    my $ValidID = $Kernel::OM->Get('Kernel::System::Valid')->ValidLookup(
        Valid => 'valid',
    );

    # get all current dynamic fields
    my $DynamicFieldList = $Kernel::OM->Get('Kernel::System::DynamicField')->DynamicFieldListGet(
        Valid => 0,
    );

    # get the list of order numbers (is already sorted).
    my @DynamicfieldOrderList;
    for my $Dynamicfield ( @{$DynamicFieldList} ) {
        push @DynamicfieldOrderList, $Dynamicfield->{FieldOrder};
    }

    # get the last element from the order list and add 1
    my $NextOrderNumber = 1;
    if (@DynamicfieldOrderList) {
        $NextOrderNumber = $DynamicfieldOrderList[-1] + 1;
    }

    # create a dynamic fields lookup table
    my %DynamicFieldLookup;
    DYNAMICFIELD:
    for my $DynamicField ( @{$DynamicFieldList} ) {
        next DYNAMICFIELD if ref $DynamicField ne 'HASH';
        $DynamicFieldLookup{ $DynamicField->{Name} } = $DynamicField;
    }

    # check if the dynamic field already exists
    if ( ref $DynamicFieldLookup{ $Self->{DynamicFieldName} } ne 'HASH' ) {

        # create a new field
        my $FieldID = $Kernel::OM->Get('Kernel::System::DynamicField')->DynamicFieldAdd(
            Name       => $Self->{DynamicFieldName},
            Label      => 'OTOBO AI',
            FieldType  => 'TextAreaAI',
            FieldOrder => $NextOrderNumber,
            ObjectType => 'Article',
            Config     => {
                DefaultValue => '',
                RegExList    => [],
                Tooltip      => '',
            },
            InternalField => 1,
            ValidID       => $ValidID,
            UserID        => 1,
        );

        if ( !$FieldID ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Could not create dynamic field $Self->{DynamicFieldName}. Please review the logs.",
            );
        }
    }
    else {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Dynamic field with name $Self->{DynamicFieldName} already exists.",
        );
    }

    return 1;
}

=head2 _DeleteAIDynamicField()

Deletes the dynamic field for AI functionality.

    my $Result = $CodeObject->_DeleteAIDynamicField();

=cut

sub _DeleteAIDynamicField {
    my ( $Self, %Param ) = @_;

    # get necessary objects
    my $DynamicFieldObject        = $Kernel::OM->Get('Kernel::System::DynamicField');
    my $DynamicFieldBackendObject = $Kernel::OM->Get('Kernel::System::DynamicField::Backend');
    my $LogObject                 = $Kernel::OM->Get('Kernel::System::Log');

    # running pre-uninstall, so we do have the sysconfig at hand
    my $DynamicFieldName = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::DynamicFieldOTOBOAI') || $Self->{DynamicFieldName};

    my $DynamicFieldConfig = $DynamicFieldObject->DynamicFieldGet(
        Name => $DynamicFieldName,
    );

    if ( !IsHashRefWithData($DynamicFieldConfig) ) {
        $LogObject->Log(
            'Priority' => 'error',
            'Message'  => "DynamicField '$DynamicFieldName' not found on the system!",
        );
        return;
    }

    my $ValuesDeleteSuccess = $DynamicFieldBackendObject->AllValuesDelete(
        DynamicFieldConfig => $DynamicFieldConfig,
        UserID             => 1,
    );

    if ( !$ValuesDeleteSuccess ) {
        $LogObject->Log(
            'Priority' => 'error',
            'Message'  => "Could not delete values for DynamicField $DynamicFieldConfig->{Name}!",
        );
    }

    my $Success = $DynamicFieldObject->DynamicFieldDelete(
        ID     => $DynamicFieldConfig->{ID},
        UserID => 1,
    );

    if ( !$Success ) {
        $LogObject->Log(
            'Priority' => 'error',
            'Message'  => "Could not delete DynamicField $DynamicFieldConfig->{Name}!",
        );
    }

    return 1;
}

sub _CreateAIAnswerTemplate {
    my ( $Self, %Param ) = @_;

    # get all valid queues
    my $QueueObject = $Kernel::OM->Get('Kernel::System::Queue');
    my %QueueData   = $QueueObject->QueueList( Valid => 1 );

    # add english template
    {
        my $TemplateID = $Kernel::OM->Get('Kernel::System::StandardTemplate')->StandardTemplateAdd(
            Name         => 'OTOBOAI Answer Template',
            Template     => 'The suggested AI answer is: <OTOBO_AIAnswer_' . $Self->{DynamicFieldName} . '>',
            ContentType  => 'text/plain; charset=utf-8',
            TemplateType => 'Answer',
            ValidID      => 1,
            UserID       => 1,
        );

        # add template to every valid queue
        for my $QueueID ( keys %QueueData ) {
            $QueueObject->QueueStandardTemplateMemberAdd(
                QueueID            => $QueueID,
                StandardTemplateID => $TemplateID,
                Active             => 1,
                UserID             => 1,
            );
        }
    }

    return 1;
}

sub _DeleteAIAnswerTemplate {
    my ( $Self, %Param ) = @_;

    my $StandardTemplateObject = $Kernel::OM->Get('Kernel::System::StandardTemplate');

    # delete template
    for my $TemplateName ( ('OTOBOAI Answer Template') ) {
        my $TemplateID = $StandardTemplateObject->StandardTemplateLookup(
            StandardTemplate => $TemplateName,
        );

        # also cleans up the queue relations before deleting
        $StandardTemplateObject->StandardTemplateDelete(
            ID => $TemplateID,
        );
    }

    return 1;
}

sub _UpdateArticleActions {

    my ( $Self, %Param ) = @_;
    my $Channel = $Param{Channel};

    # we only do this on rel-11.0
    # for rel-11_1 we can just use XML

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $MainObject   = $Kernel::OM->Get('Kernel::System::Main');

    my $ReleaseInfo = $MainObject->GetReleaseInfo(
        Directory => $ConfigObject->Get('Home'),
        Filename  => 'RELEASE',
    );

    my $Version = $ReleaseInfo->{Version};
    if ( $Version !~ /^11\.0/ ) {

        return $Self->_CleanupArticleActions( Channel => $Channel );
    }

    my $SysConfigObject = $Kernel::OM->Get('Kernel::System::SysConfig');

    my %Setting = $SysConfigObject->SettingGet(
        Name     => "Ticket::Frontend::Article::Actions###$Channel",    # (required) Setting name
        Deployed => 1,                                                  # (optional) Get deployed setting value. Default 0.
    );

    my $EffectiveValue = $Setting{EffectiveValue};

    if ( !$EffectiveValue->{AgentTicketAIChat} ) {

        my $ExclusiveLockGUID = $SysConfigObject->SettingLock(
            LockAll => 1,
            Force   => 1,    # (optional) Force locking (do not check if it's already locked by another user). Default: 0.
            UserID  => 1,    # (required)
        );

        $EffectiveValue->{AgentTicketAIChat} = {
            'Prio'   => '1007',
            'Module' => 'Kernel::Output::HTML::ArticleAction::AgentTicketAIChat',
            'Valid'  => '1'
        };

        my %Result = $SysConfigObject->SettingUpdate(
            Name              => "Ticket::Frontend::Article::Actions###$Channel",    # (required) setting name
            IsValid           => 1,                                                  # (optional) 1 or 0, modified 0
            EffectiveValue    => $EffectiveValue,                                    # (optional) only needed when IsValid is turned on
            ExclusiveLockGUID => $ExclusiveLockGUID,
            UserID            => 1,                                                  # (required) UserID
            NoValidation      => 1,                                                  # (optional) no value type validation.
        );

        $SysConfigObject->SettingUnlock(
            UnlockAll => 1,
        );

        $SysConfigObject->ConfigurationDeploy(
            Comments    => "otobo-ai package install",
            AllSettings => 1,
            Force       => 1,
            UserID      => 1,
        );

    }

    return;
}

sub _CleanupArticleActions {

    my ( $Self, %Param ) = @_;
    my $Channel = $Param{Channel};

    my $SysConfigObject = $Kernel::OM->Get('Kernel::System::SysConfig');

    my %Setting = $SysConfigObject->SettingGet(
        Name     => "Ticket::Frontend::Article::Actions###$Channel",    # (required) Setting name
        Deployed => 1,                                                  # (optional) Get deployed setting value. Default 0.
    );

    my $EffectiveValue = $Setting{EffectiveValue};

    if ( $EffectiveValue->{AgentTicketAIChat} ) {

        my $ExclusiveLockGUID = $SysConfigObject->SettingLock(
            LockAll => 1,
            Force   => 1,    # (optional) Force locking (do not check if it's already locked by another user). Default: 0.
            UserID  => 1,    # (required)
        );

        delete $EffectiveValue->{AgentTicketAIChat};

        my %Result = $SysConfigObject->SettingUpdate(
            Name              => "Ticket::Frontend::Article::Actions###$Channel",    # (required) setting name
            IsValid           => 1,                                                  # (optional) 1 or 0, modified 0
            EffectiveValue    => $EffectiveValue,                                    # (optional) only needed when IsValid is turned on
            ExclusiveLockGUID => $ExclusiveLockGUID,
            UserID            => 1,                                                  # (required) UserID
            NoValidation      => 1,                                                  # (optional) no value type validation.
        );

        $SysConfigObject->SettingUnlock(
            UnlockAll => 1,
        );

        $SysConfigObject->ConfigurationDeploy(
            Comments    => "otobo-ai package install",
            AllSettings => 1,
            Force       => 1,
            UserID      => 1,
        );

    }

    return;
}

1;
