@IsTest
private class DynamicFormSchemaServiceTest {

    @TestSetup
    static void setup() {
        // Standalone Account form: two sections, one field per section.
        Form_Configuration__c accountForm = new Form_Configuration__c(
            Name = 'Account Form',
            Form_Display_Title__c = 'Create Account',
            Object_API_Name__c = 'Account',
            Is_Active__c = true,
            DML_Operations__c = 'Insert;Update',
            Insert_Button_Label__c = 'Create',
            Update_Button_Label__c = 'Save Changes',
            Success_Message_Insert__c = 'Account created!',
            Success_Message_Update__c = 'Account updated!'
        );
        insert accountForm;

        insert new List<Form_Field_Configuration__c>{
            new Form_Field_Configuration__c(
                Form_Configuration__c = accountForm.Id,
                Field_API_Name__c = 'Name',
                Section_Name__c = 'Basic Info',
                Section_Order__c = 1,
                Field_Order__c = 1,
                Is_Required__c = true,
                Is_Active__c = true,
                Display_Layout__c = '1-Column'
            ),
            new Form_Field_Configuration__c(
                Form_Configuration__c = accountForm.Id,
                Field_API_Name__c = 'BillingCity',
                Section_Name__c = 'Address',
                Section_Order__c = 2,
                Field_Order__c = 1,
                Is_Active__c = true,
                Display_Layout__c = '2-Column'
            ),
            new Form_Field_Configuration__c(
                Form_Configuration__c = accountForm.Id,
                Field_API_Name__c = 'Field_That_Does_Not_Exist__c',
                Section_Name__c = 'Address',
                Section_Order__c = 2,
                Field_Order__c = 2,
                Is_Active__c = true
            )
        };

        // Composite master: Account (step 1) -> Contact (step 2, linked via AccountId).
        Form_Configuration__c compositeMaster = new Form_Configuration__c(
            Name = 'Vendor Onboarding',
            Object_API_Name__c = 'Account',
            Is_Active__c = true,
            Is_Composite__c = true,
            Failure_Handling__c = 'Rollback All Steps',
            DML_Operations__c = 'Insert'
        );
        insert compositeMaster;

        Form_Configuration__c step1 = new Form_Configuration__c(
            Name = 'Vendor Onboarding - Step 1 Account',
            Object_API_Name__c = 'Account',
            Is_Active__c = true,
            Parent_Form_Configuration__c = compositeMaster.Id,
            Step_Order__c = 1,
            DML_Operations__c = 'Insert'
        );
        Form_Configuration__c step2 = new Form_Configuration__c(
            Name = 'Vendor Onboarding - Step 2 Contact',
            Object_API_Name__c = 'Contact',
            Is_Active__c = true,
            Parent_Form_Configuration__c = compositeMaster.Id,
            Step_Order__c = 2,
            Link_Field_API_Name__c = 'AccountId',
            DML_Operations__c = 'Insert'
        );
        insert new List<Form_Configuration__c>{ step1, step2 };

        insert new Form_Field_Configuration__c(
            Form_Configuration__c = step1.Id,
            Field_API_Name__c = 'Name',
            Section_Name__c = 'Account Details',
            Section_Order__c = 1,
            Field_Order__c = 1,
            Is_Required__c = true,
            Is_Active__c = true
        );
        insert new Form_Field_Configuration__c(
            Form_Configuration__c = step2.Id,
            Field_API_Name__c = 'LastName',
            Section_Name__c = 'Contact Details',
            Section_Order__c = 1,
            Field_Order__c = 1,
            Is_Required__c = true,
            Is_Active__c = true
        );
    }

    @IsTest
    static void testGetFormSchema_insertMode_buildsSectionsAndSkipsUnknownField() {
        Form_Configuration__c config = [SELECT Id FROM Form_Configuration__c WHERE Name = 'Account Form' LIMIT 1];

        Test.startTest();
        DynamicFormWrappers.FormSchema schema = DynamicFormSchemaService.getFormSchema(config.Id, null);
        Test.stopTest();

        System.assertEquals('Insert', schema.mode, 'No recordId supplied - form should render in Insert mode.');
        System.assertEquals('Create Account', schema.formTitle);
        System.assertEquals(2, schema.sections.size(), 'Two sections were configured.');

        Integer totalFields = 0;
        for (DynamicFormWrappers.SectionSchema s : schema.sections) {
            totalFields += s.fields.size();
        }
        // 3 field configs were inserted, but one points at a non-existent field
        // and must be silently skipped rather than breaking schema generation.
        System.assertEquals(2, totalFields, 'The non-existent field config should have been skipped.');
    }

    @IsTest
    static void testGetFormSchema_updateMode_prefillsExistingValues() {
        Form_Configuration__c config = [SELECT Id FROM Form_Configuration__c WHERE Name = 'Account Form' LIMIT 1];
        Account acct = new Account(Name = 'Existing Test Account', BillingCity = 'Pune');
        insert acct;

        Test.startTest();
        DynamicFormWrappers.FormSchema schema = DynamicFormSchemaService.getFormSchema(config.Id, acct.Id);
        Test.stopTest();

        System.assertEquals('Update', schema.mode, 'Matching object type + Update supported should switch to Update mode.');
        System.assertEquals(acct.Id, schema.recordId);

        Boolean foundPrefilledName = false;
        for (DynamicFormWrappers.SectionSchema s : schema.sections) {
            for (DynamicFormWrappers.FieldSchema f : s.fields) {
                if (f.apiName == 'Name') {
                    System.assertEquals('Existing Test Account', f.currentValue);
                    foundPrefilledName = true;
                }
            }
        }
        System.assert(foundPrefilledName, 'Name field should have been prefilled from the existing record.');
    }

    @IsTest
    static void testGetFormSchema_mismatchedRecordType_fallsBackToInsert() {
        Form_Configuration__c config = [SELECT Id FROM Form_Configuration__c WHERE Name = 'Account Form' LIMIT 1];
        Contact con = new Contact(LastName = 'Mismatch Test');
        insert con;

        Test.startTest();
        // Account-targeted form given a Contact recordId - types don't match.
        DynamicFormWrappers.FormSchema schema = DynamicFormSchemaService.getFormSchema(config.Id, con.Id);
        Test.stopTest();

        System.assertEquals('Insert', schema.mode, 'Mismatched object type must fall back to a blank Insert form.');
        System.assertEquals(null, schema.recordId);
    }

    @IsTest
    static void testGetFormSchema_compositeMaster_returnsOrderedSteps() {
        Form_Configuration__c master = [SELECT Id FROM Form_Configuration__c WHERE Name = 'Vendor Onboarding' LIMIT 1];

        Test.startTest();
        DynamicFormWrappers.FormSchema schema = DynamicFormSchemaService.getFormSchema(master.Id, null);
        Test.stopTest();

        System.assertEquals(true, schema.isComposite);
        System.assertEquals(2, schema.compositeSteps.size());
        System.assertEquals(1, schema.compositeSteps[0].stepOrder);
        System.assertEquals('Account', schema.compositeSteps[0].objectApiName);
        System.assertEquals(2, schema.compositeSteps[1].stepOrder);
        System.assertEquals('Contact', schema.compositeSteps[1].objectApiName);
        System.assertEquals('AccountId', schema.compositeSteps[1].linkFieldApiName);
    }

    @IsTest
    static void testGetFormSchema_inactiveForm_throws() {
        Form_Configuration__c config = [SELECT Id FROM Form_Configuration__c WHERE Name = 'Account Form' LIMIT 1];
        config.Is_Active__c = false;
        update config;

        Test.startTest();
        try {
            DynamicFormSchemaService.getFormSchema(config.Id, null);
            System.assert(false, 'Expected an AuraHandledException for an inactive form.');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetFormSchema_nullFormConfigId_throws() {
        Test.startTest();
        try {
            DynamicFormSchemaService.getFormSchema(null, null);
            System.assert(false, 'Expected an AuraHandledException for a null Id.');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }
}