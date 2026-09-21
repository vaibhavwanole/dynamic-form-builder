@IsTest
private class DynamicFormSubmissionServiceTest {

    @TestSetup
    static void setup() {
        Form_Configuration__c accountForm = new Form_Configuration__c(
            Name = 'Account Form',
            Object_API_Name__c = 'Account',
            Is_Active__c = true,
            DML_Operations__c = 'Insert;Update',
            Success_Message_Insert__c = 'Account created!',
            Success_Message_Update__c = 'Account updated!'
        );
        insert accountForm;

        // Composite: Account (rollback mode) -> Contact, linked via AccountId.
        Form_Configuration__c rollbackMaster = new Form_Configuration__c(
            Name = 'Composite Rollback',
            Object_API_Name__c = 'Account',
            Is_Active__c = true,
            Is_Composite__c = true,
            Failure_Handling__c = 'Rollback All Steps'
        );
        Form_Configuration__c retryMaster = new Form_Configuration__c(
            Name = 'Composite Retry',
            Object_API_Name__c = 'Account',
            Is_Active__c = true,
            Is_Composite__c = true,
            Failure_Handling__c = 'Retry Failed Step Only'
        );
        insert new List<Form_Configuration__c>{ rollbackMaster, retryMaster };

        List<Form_Configuration__c> steps = new List<Form_Configuration__c>();
        for (Form_Configuration__c master : new List<Form_Configuration__c>{ rollbackMaster, retryMaster }) {
            steps.add(new Form_Configuration__c(
                Name = master.Name + ' - Step 1 Account',
                Object_API_Name__c = 'Account',
                Is_Active__c = true,
                Parent_Form_Configuration__c = master.Id,
                Step_Order__c = 1
            ));
            steps.add(new Form_Configuration__c(
                Name = master.Name + ' - Step 2 Contact',
                Object_API_Name__c = 'Contact',
                Is_Active__c = true,
                Parent_Form_Configuration__c = master.Id,
                Step_Order__c = 2,
                Link_Field_API_Name__c = 'AccountId'
            ));
        }
        insert steps;
    }

    @IsTest
    static void testSubmitForm_insert_succeeds() {
        Form_Configuration__c config = [SELECT Id FROM Form_Configuration__c WHERE Name = 'Account Form' LIMIT 1];
        Map<String, Object> values = new Map<String, Object>{ 'Name' => 'New Test Account', 'BillingCity' => 'Pune' };

        Test.startTest();
        DynamicFormWrappers.SubmitResult result = DynamicFormSubmissionService.submitForm(config.Id, null, values);
        Test.stopTest();

        System.assert(result.success, 'Insert should succeed: ' + result.errorMessage);
        System.assertEquals('Account created!', result.message);
        Account inserted = [SELECT Name, BillingCity FROM Account WHERE Id = :result.recordId];
        System.assertEquals('New Test Account', inserted.Name);
        System.assertEquals('Pune', inserted.BillingCity);
    }

    @IsTest
    static void testSubmitForm_update_succeeds() {
        Form_Configuration__c config = [SELECT Id FROM Form_Configuration__c WHERE Name = 'Account Form' LIMIT 1];
        Account acct = new Account(Name = 'Original Name');
        insert acct;

        Map<String, Object> values = new Map<String, Object>{ 'Name' => 'Renamed Account' };

        Test.startTest();
        DynamicFormWrappers.SubmitResult result = DynamicFormSubmissionService.submitForm(config.Id, acct.Id, values);
        Test.stopTest();

        System.assert(result.success, 'Update should succeed: ' + result.errorMessage);
        System.assertEquals('Account updated!', result.message);
        System.assertEquals('Renamed Account', [SELECT Name FROM Account WHERE Id = :acct.Id].Name);
    }

    @IsTest
    static void testSubmitForm_requiredFieldMissing_throwsFriendlyError() {
        Form_Configuration__c config = [SELECT Id FROM Form_Configuration__c WHERE Name = 'Account Form' LIMIT 1];
        // Account.Name is not-nillable at the schema level - omitting it should
        // be caught by the required-field check before DML is even attempted.
        Map<String, Object> values = new Map<String, Object>{ 'Name' => '' };

        Test.startTest();
        try {
            DynamicFormSubmissionService.submitForm(config.Id, null, values);
            System.assert(false, 'Expected an AuraHandledException for a missing required field.');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSubmitForm_unknownFieldIgnoredSilently() {
        Form_Configuration__c config = [SELECT Id FROM Form_Configuration__c WHERE Name = 'Account Form' LIMIT 1];
        Map<String, Object> values = new Map<String, Object>{
            'Name' => 'Account With Junk Field',
            'This_Field_Does_Not_Exist__c' => 'ignored'
        };

        Test.startTest();
        DynamicFormWrappers.SubmitResult result = DynamicFormSubmissionService.submitForm(config.Id, null, values);
        Test.stopTest();

        System.assert(result.success, 'A crafted/unknown field must not break submission: ' + result.errorMessage);
    }

    @IsTest
    static void testSubmitComposite_bothStepsSucceed_linksSecondStepToFirst() {
        Form_Configuration__c master = [SELECT Id FROM Form_Configuration__c WHERE Name = 'Composite Rollback' LIMIT 1];
        List<Form_Configuration__c> stepConfigs = [
            SELECT Id, Step_Order__c FROM Form_Configuration__c
            WHERE Parent_Form_Configuration__c = :master.Id ORDER BY Step_Order__c ASC
        ];

        DynamicFormWrappers.StepSubmission step1 = new DynamicFormWrappers.StepSubmission();
        step1.formConfigId = stepConfigs[0].Id;
        step1.stepOrder = 1;
        step1.fieldValues = new Map<String, Object>{ 'Name' => 'Composite Test Account' };

        DynamicFormWrappers.StepSubmission step2 = new DynamicFormWrappers.StepSubmission();
        step2.formConfigId = stepConfigs[1].Id;
        step2.stepOrder = 2;
        step2.fieldValues = new Map<String, Object>{ 'LastName' => 'Composite Test Contact' };

        Test.startTest();
        DynamicFormWrappers.CompositeSubmitResult result = DynamicFormSubmissionService.submitComposite(
            master.Id, new List<DynamicFormWrappers.StepSubmission>{ step1, step2 }
        );
        Test.stopTest();

        System.assert(result.success, 'Both steps should succeed: ' + result.errorMessage);
        Id accountId = result.committedRecordIdsByStep.get(1);
        Id contactId = result.committedRecordIdsByStep.get(2);
        System.assertNotEquals(null, accountId);
        System.assertNotEquals(null, contactId);

        Contact createdContact = [SELECT AccountId FROM Contact WHERE Id = :contactId];
        System.assertEquals(accountId, createdContact.AccountId, 'Step 2 should be auto-linked to Step 1 via AccountId.');
    }

    @IsTest
    static void testSubmitComposite_rollbackMode_undoesEarlierStepOnFailure() {
        Form_Configuration__c master = [SELECT Id FROM Form_Configuration__c WHERE Name = 'Composite Rollback' LIMIT 1];
        List<Form_Configuration__c> stepConfigs = [
            SELECT Id, Step_Order__c FROM Form_Configuration__c
            WHERE Parent_Form_Configuration__c = :master.Id ORDER BY Step_Order__c ASC
        ];

        DynamicFormWrappers.StepSubmission step1 = new DynamicFormWrappers.StepSubmission();
        step1.formConfigId = stepConfigs[0].Id;
        step1.stepOrder = 1;
        step1.fieldValues = new Map<String, Object>{ 'Name' => 'Rollback Test Account' };

        DynamicFormWrappers.StepSubmission step2 = new DynamicFormWrappers.StepSubmission();
        step2.formConfigId = stepConfigs[1].Id;
        step2.stepOrder = 2;
        // Missing LastName - Contact requires it, so this step should fail.
        step2.fieldValues = new Map<String, Object>{ 'LastName' => '' };

        Integer accountCountBefore = [SELECT COUNT() FROM Account WHERE Name = 'Rollback Test Account'];

        Test.startTest();
        DynamicFormWrappers.CompositeSubmitResult result = DynamicFormSubmissionService.submitComposite(
            master.Id, new List<DynamicFormWrappers.StepSubmission>{ step1, step2 }
        );
        Test.stopTest();

        System.assert(!result.success, 'Step 2 should fail due to missing required LastName.');
        System.assertEquals(2, result.failedStepOrder);

        Integer accountCountAfter = [SELECT COUNT() FROM Account WHERE Name = 'Rollback Test Account'];
        System.assertEquals(accountCountBefore, accountCountAfter, 'Rollback mode must undo the Step 1 Account insert too.');
    }

    @IsTest
    static void testSubmitComposite_retryMode_keepsSuccessfulStepCommitted() {
        Form_Configuration__c master = [SELECT Id FROM Form_Configuration__c WHERE Name = 'Composite Retry' LIMIT 1];
        List<Form_Configuration__c> stepConfigs = [
            SELECT Id, Step_Order__c FROM Form_Configuration__c
            WHERE Parent_Form_Configuration__c = :master.Id ORDER BY Step_Order__c ASC
        ];

        DynamicFormWrappers.StepSubmission step1 = new DynamicFormWrappers.StepSubmission();
        step1.formConfigId = stepConfigs[0].Id;
        step1.stepOrder = 1;
        step1.fieldValues = new Map<String, Object>{ 'Name' => 'Retry Test Account' };

        DynamicFormWrappers.StepSubmission step2 = new DynamicFormWrappers.StepSubmission();
        step2.formConfigId = stepConfigs[1].Id;
        step2.stepOrder = 2;
        step2.fieldValues = new Map<String, Object>{ 'LastName' => '' }; // will fail

        Test.startTest();
        DynamicFormWrappers.CompositeSubmitResult result = DynamicFormSubmissionService.submitComposite(
            master.Id, new List<DynamicFormWrappers.StepSubmission>{ step1, step2 }
        );
        Test.stopTest();

        System.assert(!result.success);
        System.assertEquals(2, result.failedStepOrder);
        Id accountId = result.committedRecordIdsByStep.get(1);
        System.assertNotEquals(null, accountId, 'Retry mode should keep the successfully committed Step 1 record.');
        System.assertEquals(1, [SELECT COUNT() FROM Account WHERE Name = 'Retry Test Account']);
    }
}