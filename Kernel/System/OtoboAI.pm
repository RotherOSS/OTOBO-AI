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

package Kernel::System::OtoboAI;

use strict;
use warnings;

# core modules

# CPAN modules

# OTOBO modules
use Kernel::System::VariableCheck qw(IsHashRefWithData);

use parent qw(Kernel::System::AsynchronousExecutor);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::GenericInterface::Requester',
    'Kernel::System::Cache',
    'Kernel::System::DynamicField',
    'Kernel::System::DynamicField::Backend',
    'Kernel::System::GenericInterface::Webservice',
    'Kernel::System::Log',
    'Kernel::System::Main',
    'Kernel::System::Ticket::Article',
);

=head1 NAME

Kernel::System::OtoboAI - get OtoboAI GetAnswer for a Question or an ArticleID

=head1 DESCRIPTION

call OtoboAI GetAnswer synchronously or asynchronously

=head2 new()

create a OtoboAI object. Do not use it directly, instead use:

    my $OtoboAIObject = $Kernel::OM->Get('Kernel::System::OtoboAI');

=cut

sub new {

    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {%Param};
    bless( $Self, $Type );

    my $StripSignatureRegEx = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::StripSignatureRegex');
    if ($StripSignatureRegEx) {

        my $Regex = qr/$StripSignatureRegEx/m;
        $Self->{StripSignatureRegEx} = $Regex;
    }

    return $Self;
}

=head2 GetAnswerAsync()

Get an OtoboAI Answer asynchronously.

    my $Success = $OtoboAIObject->GetAnswerAsync(
        Question => '<some ai question>',  # the question to ask the LLM
        ObjectID => $ArticleID,            # if given, construct question from Article Subject+Body
                                           # results will be stored in this Articles AIResult DynamicField
        UserID   => $UserID,               # if specified, and this was a question, populate user specfic cache key
    );

=cut

sub GetAnswerAsync {
    my ( $Self, %Param ) = @_;

    if ( !$Param{ObjectID} && !$Param{Question} ) {

        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Need either ObjectID or Question param.",
        );
        return;
    }

    $Kernel::OM->Get('Kernel::System::Log')->Log(
        Priority => 'debug',
        Message  => "OtoboAI::GetAnswerAsync call initiated.",
    );

    my $Success = $Self->AsyncCall(
        ObjectName               => 'Kernel::System::OtoboAI',    # optional, if not given the object is used from where
                                                                  # this function was called
        FunctionName             => 'GetAnswer',                  # the name of the function to execute
        FunctionParams           => \%Param,                      # a ref with the required parameters for the function
        Attempts                 => 1,                            # optional, default: 1, number of tries to lock the
                                                                  #   task by the scheduler
        MaximumParallelInstances => 0,                            # optional, default: 0 (unlimited), number of same
                                                                  #   function calls from the same object that can be
                                                                  #   executed at the same time
    );

    if ( !$Success ) {

        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Initialize async call failed!",
        );
        return;
    }

    return 1;
}

=head2 GetAnswer()

Get an OtoboAI Answer synchronously. If called from GetAnswerAsync(), this will happen on a Daemon thread.

    my $Result = $OtoboAIObject->GetAnswer(
        Question => '<some ai question>',  # the question to ask the LLM
        ObjectID => $ArticleID,            # if given, construct question from Article Subject+Body
                                           # results will be stored in this Articles AIResult DynamicField
        UserID   => $UserID,               # if specified, and this was a question, populate user specfic cache key
        Persist  => 1|0,                   # optional, default is 1. Whether to persist Result in DF (with ObjectID) or
                                           # poplate the use specific cache key
        DoScoring => 0|1,                  # ask LLM to do the extra evaluation step, used by Maint::AI::Scoring
                                           # console command
    );

    # on success
    $Result = {
        Success => 1,
        Data => {
            Answer => 'the AI answer as text',
            Score  => 'The AI evaluation score %.',  # only if scoring is activated, see SysConfig
        },
    }

    # on error
    $Result = {
        Success => 0,
        Error => "SomeErrorMsg",
    }

=cut

sub GetAnswer {
    my ( $Self, %Param ) = @_;

    if ( !$Param{ObjectID} && !$Param{Question} ) {

        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Need either ObjectID or Question param.",
        );
        return;
    }

    my $DoScoring = $Param{DoScoring} // 0;

    my $ErrorMessage = '';
    my $Success      = 0;

    # check whether otobo AI is enabled and if not, activate it
    my $WebserviceObject = $Kernel::OM->Get('Kernel::System::GenericInterface::Webservice');

    my $AIWebservice = $WebserviceObject->WebserviceGet(
        Name => 'OTOBO-AI',
    );

    if ( !$AIWebservice ) {

        $ErrorMessage = "OTOBO-AI webservice not found! Unable to continue.";
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => $ErrorMessage,
        );

        return {
            Success => $Success,
            Error   => $ErrorMessage,
        };
    }

    # Set the webservice id
    $Self->{WebserviceID} = $AIWebservice->{ID};

    # prepare the question
    my $ObjectID = $Param{ObjectID};
    my $UserID   = $Param{UserID};
    my $Persist  = $Param{Persist} // 1;
    my $Question;

    if ($ObjectID) {

        my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');

        my $ArticleID = $ObjectID;
        my $TicketID  = $ArticleObject->TicketIDLookup(
            ArticleID => $ArticleID,
        );

        my $ArticleBackendObject = $ArticleObject->BackendForArticle(
            TicketID  => $TicketID,
            ArticleID => $ArticleID,
        );

        my %Article = $ArticleBackendObject->ArticleGet(
            TicketID  => $TicketID,
            ArticleID => $ArticleID,
        );

        if ( !$Article{Body} ) {
            return {
                Success      => 0,
                ErrorMessage => "No body in the article!",
            };
        }

        my $Subject = $Article{Subject} // '';
        my $Body    = $Article{Body}    // '';

        $Body     = $Self->_StripSignature( Body => $Body );
        $Question = $Subject . '. ' . $Body;
    }
    else {

        $Question = $Param{Question};
    }

    my $Result = $Kernel::OM->Get('Kernel::GenericInterface::Requester')->Run(
        WebserviceID => $Self->{WebserviceID},
        Invoker      => 'GetAnswer',
        Asynchronous => 0,
        Data         => {
            Question  => $Question,
            DoScoring => $DoScoring,
        }
    );

    my $MainObject = $Kernel::OM->Get('Kernel::System::Main');
    my $Dump       = $MainObject->Dump($Result);

    $Kernel::OM->Get('Kernel::System::Log')->Log(
        Priority => 'debug',
        Message  => "OtoboAI GetAnswer Result: $Dump",
    );

    my $Answer = $Result->{Data}{Answer} || "";

    # set dynamic field value if ObjectID was given
    if ( $ObjectID && $Persist ) {

        # fetching dynamic field config
        my $DynamicFieldName = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::DynamicFieldOTOBOAI') || 'OTOBOAI';
        my $OTOBOAIDFConfig  = $Kernel::OM->Get('Kernel::System::DynamicField')->DynamicFieldGet(
            Name => $DynamicFieldName,
        );
        if ( !IsHashRefWithData($OTOBOAIDFConfig) ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "DynamicField '$DynamicFieldName' not found on the system!",
            );
            return;
        }

        $Kernel::OM->Get('Kernel::System::DynamicField::Backend')->ValueSet(
            DynamicFieldConfig => $OTOBOAIDFConfig,
            ObjectID           => $ObjectID,
            Value              => $Answer,
            DoWrite            => 1,
            UserID             => 1,
        );
    }
    elsif ( $UserID && $Persist ) {
        my $CacheObject      = $Kernel::OM->Get('Kernel::System::Cache');
        my $MainObject       = $Kernel::OM->Get('Kernel::System::Main');
        my $QuestionMd5      = $MainObject->MD5sum( String => \$Question );
        my $CacheKeyQuestion = 'OtoboAI-Custom-Response-' . $QuestionMd5;
        my $TTL              = $Kernel::OM->Get('Kernel::Config')->Get('OtoboAIDashboard::Frontend::CacheTTL')->{Answer} || 24;
        $CacheObject->Set(
            Type  => 'OtoboAI',
            Key   => $CacheKeyQuestion,
            Value => $Answer,
            TTL   => 60 * 60 * $TTL,
        );
    }

    return {
        Success => 1,
        Data    => $Result->{Data},
    };
}

sub _StripSignature {

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
