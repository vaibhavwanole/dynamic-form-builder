/**
 * DynamicFormSchemaService
 * -------------------------
 * Resolves a Form_Configuration__c (and its Form_Field_Configuration__c children)
 * into a fully rendered DynamicFormWrappers.FormSchema for the LWC layer.
 *
 * Security model:
 *  - Config records (Form_Configuration__c / Form_Field_Configuration__c) are read
 *    in SYSTEM_MODE only when the form is flagged Available_For_Guest_Users__c,
 *    since guest profiles typically cannot see configuration objects directly.
 *    This never exposes target-object *data* — only form structure.
 *  - Every target-object field is filtered through isAccessible() before it is
 *    ever included in the schema. A field the running user cannot see is
 *    simply omitted, exactly as lightning-record-edit-form would behave.
 *  - Record prefill (Update mode) queries the target object with USER_MODE,
 *    and only for fields that already passed the isAccessible() filter above.
 */
public with sharing class DynamicFormSchemaService {

    private static final String MODE_INSERT = 'Insert';
    private static final String MODE_UPDATE = 'Update';

    /**
     * Main entry point used by the LWC engine.
     * @param formConfigId  Id of the Form_Configuration__c to render.
     * @param recordId      Optional - the record currently in context (e.g. from
     *                      a Record Page's @api recordId). Used for prefill when
     *                      its object type matches the form's configured object.
     */
    @AuraEnabled(cacheable=true)
    public static DynamicFormWrappers.FormSchema getFormSchema(Id formConfigId, Id recordId) {
        if (formConfigId == null) {
            throw new AuraHandledException('A Form Configuration Id is required.');
        }

        Form_Configuration__c config = fetchConfig(formConfigId);
        if (config == null || config.Is_Active__c != true) {
            throw new AuraHandledException('This form is not available.');
        }

        DynamicFormWrappers.FormSchema formSchema = buildSchema(config, recordId);

        // Composite master: resolve each step's own schema too, so the LWC
        // can render the full wizard without another round trip per step.
        if (config.Is_Composite__c == true) {
            formSchema.compositeSteps = new List<DynamicFormWrappers.CompositeStep>();
            List<Form_Configuration__c> stepConfigs = fetchCompositeSteps(formConfigId);
            for (Form_Configuration__c stepConfig : stepConfigs) {
                DynamicFormWrappers.CompositeStep step = new DynamicFormWrappers.CompositeStep();
                step.formConfigId = stepConfig.Id;
                step.stepOrder = stepConfig.Step_Order__c != null ? Integer.valueOf(stepConfig.Step_Order__c) : 0;
                step.objectApiName = stepConfig.Object_API_Name__c;
                step.linkFieldApiName = stepConfig.Link_Field_API_Name__c;
                // Steps never prefill from the top-level recordId directly -
                // only the first step might, if its object type matches.
                Id stepRecordId = (step.stepOrder == 1) ? recordId : null;
                step.stepSchema = buildSchema(stepConfig, stepRecordId);
                formSchema.compositeSteps.add(step);
            }
            // Keep steps predictable for the wizard UI.
            formSchema.compositeSteps.sort();
        }

        return formSchema;
    }

    // -----------------------------------------------------------------
    // Config retrieval
    // -----------------------------------------------------------------

    /**
     * Lists active, top-level forms (excludes composite step-configs, which
     * are never selected directly) for the LWC's form picker dropdown.
     * Reuses PicklistOption purely for its {label, value} shape - value
     * holds the Form_Configuration__c Id as a String.
     */
    @AuraEnabled(cacheable=true)
    public static List<DynamicFormWrappers.PicklistOption> getActiveFormConfigs() {
        List<DynamicFormWrappers.PicklistOption> options = new List<DynamicFormWrappers.PicklistOption>();
        List<Form_Configuration__c> configs = [
            SELECT Id, Name, Form_Display_Title__c
            FROM Form_Configuration__c
            WHERE Is_Active__c = true AND Parent_Form_Configuration__c = null
            WITH USER_MODE
            ORDER BY Name ASC
        ];
        for (Form_Configuration__c c : configs) {
            String label = String.isNotBlank(c.Form_Display_Title__c) ? c.Form_Display_Title__c : c.Name;
            options.add(new DynamicFormWrappers.PicklistOption(label, c.Id));
        }
        return options;
    }

    private static Form_Configuration__c fetchConfig(Id formConfigId) {
        Id boundId = formConfigId;
        String soql =
            'SELECT Id, Name, Form_Display_Title__c, Object_API_Name__c, Is_Active__c, ' +
            'Insert_Button_Label__c, Update_Button_Label__c, Disable_Form_Validations__c, ' +
            'DML_Operations__c, Success_Message_Insert__c, Success_Message_Update__c, ' +
            'Available_For_Guest_Users__c, Is_Composite__c, Failure_Handling__c, ' +
            'Link_Field_API_Name__c, Step_Order__c ' +
            'FROM Form_Configuration__c WHERE Id = :boundId LIMIT 1';

        List<Form_Configuration__c> results = queryConfigRespectingGuestAccess(soql, boundId);
        return results.isEmpty() ? null : results[0];
    }

    private static List<Form_Configuration__c> fetchCompositeSteps(Id masterFormConfigId) {
        Id boundId = masterFormConfigId;
        String soql =
            'SELECT Id, Name, Form_Display_Title__c, Object_API_Name__c, Is_Active__c, ' +
            'Insert_Button_Label__c, Update_Button_Label__c, Disable_Form_Validations__c, ' +
            'DML_Operations__c, Success_Message_Insert__c, Success_Message_Update__c, ' +
            'Available_For_Guest_Users__c, Is_Composite__c, Failure_Handling__c, ' +
            'Link_Field_API_Name__c, Step_Order__c ' +
            'FROM Form_Configuration__c WHERE Parent_Form_Configuration__c = :boundId ' +
            'AND Is_Active__c = true ORDER BY Step_Order__c ASC';

        return queryConfigRespectingGuestAccess(soql, boundId);
    }

    /**
     * Config objects need to be readable by guest users even though guest
     * profiles are rarely granted direct access to them - hence the
     * SYSTEM_MODE branch. We look up Available_For_Guest_Users__c with a
     * lightweight system-mode probe first since we can't know the flag's
     * value until we've read the record.
     *
     * IMPORTANT: the bind variable in each caller's SOQL string must be
     * named exactly `boundId` to match this method's parameter - Apex
     * resolves dynamic SOQL bind variables against the scope of the method
     * where Database.query() actually executes, not where the string was built.
     */
    private static List<Form_Configuration__c> queryConfigRespectingGuestAccess(String soql, Id boundId) {
        // First, attempt USER_MODE (the safe default for authenticated/admin contexts).
        try {
            return Database.query(soql, AccessLevel.USER_MODE);
        } catch (System.NoAccessException nae) {
            // Fall back to SYSTEM_MODE only to read configuration structure -
            // never used for target-object data.
            List<Form_Configuration__c> systemModeResult = Database.query(soql, AccessLevel.SYSTEM_MODE);
            if (!systemModeResult.isEmpty() && systemModeResult[0].Available_For_Guest_Users__c == true) {
                return systemModeResult;
            }
            // Not a guest-enabled form - re-throw the original access problem.
            throw nae;
        }
    }

    // -----------------------------------------------------------------
    // Schema building
    // -----------------------------------------------------------------

    private static DynamicFormWrappers.FormSchema buildSchema(Form_Configuration__c config, Id recordId) {
        DynamicFormWrappers.FormSchema formSchema = new DynamicFormWrappers.FormSchema();
        formSchema.formConfigId = config.Id;
        formSchema.formTitle = String.isNotBlank(config.Form_Display_Title__c) ? config.Form_Display_Title__c : config.Name;
        formSchema.objectApiName = config.Object_API_Name__c;
        formSchema.insertButtonLabel = String.isNotBlank(config.Insert_Button_Label__c) ? config.Insert_Button_Label__c : 'Submit';
        formSchema.updateButtonLabel = String.isNotBlank(config.Update_Button_Label__c) ? config.Update_Button_Label__c : 'Save';
        formSchema.successMessageInsert = config.Success_Message_Insert__c;
        formSchema.successMessageUpdate = config.Success_Message_Update__c;
        formSchema.disableValidations = config.Disable_Form_Validations__c == true;
        formSchema.isComposite = config.Is_Composite__c == true;
        formSchema.failureHandling = config.Failure_Handling__c;

        Set<String> supportedOps = splitMultiPicklist(config.DML_Operations__c);

        // Describe the target object once, up front - every field lookup
        // below reuses this map rather than re-describing per field.
        Schema.SObjectType targetType = Schema.getGlobalDescribe().get(config.Object_API_Name__c.toLowerCase());
        if (targetType == null) {
            throw new AuraHandledException('Configured object "' + config.Object_API_Name__c + '" was not found.');
        }
        Map<String, Schema.SObjectField> fieldMap = targetType.getDescribe().fields.getMap();

        // Decide Insert vs Update mode: only switches to Update when a
        // recordId is supplied AND its object type matches this form's
        // configured object AND Update is a supported operation.
        Boolean typeMatches = recordId != null && recordId.getSObjectType() == targetType;
        Boolean updateSupported = supportedOps.contains('Update') || supportedOps.contains('Upsert');
        formSchema.mode = (typeMatches && updateSupported) ? MODE_UPDATE : MODE_INSERT;
        formSchema.recordId = (formSchema.mode == MODE_UPDATE) ? recordId : null;

        // Fetch and group active field configs into ordered sections.
        List<Form_Field_Configuration__c> fieldConfigs = fetchFieldConfigs(config.Id);
        Map<String, DynamicFormWrappers.SectionSchema> sectionsByName = new Map<String, DynamicFormWrappers.SectionSchema>();
        List<DynamicFormWrappers.FieldSchema> allResolvedFields = new List<DynamicFormWrappers.FieldSchema>();

        for (Form_Field_Configuration__c fc : fieldConfigs) {
            DynamicFormWrappers.FieldSchema fieldSchema = resolveField(fc, fieldMap);
            if (fieldSchema == null) {
                continue; // filtered out by FLS - never rendered, never queried for value
            }
            allResolvedFields.add(fieldSchema);

            String sectionKey = String.isNotBlank(fc.Section_Name__c) ? fc.Section_Name__c : 'General';
            DynamicFormWrappers.SectionSchema section = sectionsByName.get(sectionKey);
            if (section == null) {
                section = new DynamicFormWrappers.SectionSchema();
                section.sectionName = sectionKey;
                section.sectionDescription = fc.Section_Description__c;
                section.sectionOrder = fc.Section_Order__c != null ? Integer.valueOf(fc.Section_Order__c) : 0;
                section.displayLayout = String.isNotBlank(fc.Display_Layout__c) ? fc.Display_Layout__c : '1-Column';
                section.fields = new List<DynamicFormWrappers.FieldSchema>();
                sectionsByName.put(sectionKey, section);
            }
            section.fields.add(fieldSchema);
        }

        formSchema.sections = new List<DynamicFormWrappers.SectionSchema>(sectionsByName.values());
        for (DynamicFormWrappers.SectionSchema section : formSchema.sections) {
            section.fields.sort();
        }
        formSchema.sections.sort();

        // Prefill in Update mode - only for fields that survived the FLS filter above.
        if (formSchema.mode == MODE_UPDATE && !allResolvedFields.isEmpty()) {
            prefillCurrentValues(config.Object_API_Name__c, recordId, allResolvedFields);
        }

        return formSchema;
    }

    private static List<Form_Field_Configuration__c> fetchFieldConfigs(Id formConfigId) {
        return [
            SELECT Id, Field_API_Name__c, Field_Label__c, Field_Order__c, Section_Name__c,
                   Section_Order__c, Section_Description__c, Display_Layout__c, Is_Required__c,
                   Is_Active__c, Read_Only__c, Default_Value__c, Input_Place_holder_Value__c,
                   Help_Text__c, Validation_Pattern__c, Validation_Error__c, Field_Data_Type__c,
                   Picklist_Values__c, Lookup_Object_API_Name__c, Lookup_Display_Field__c,
                   Lookup_Filter__c, Conditional_Rules__c
            FROM Form_Field_Configuration__c
            WHERE Form_Configuration__c = :formConfigId AND Is_Active__c = true
            WITH USER_MODE
            ORDER BY Section_Order__c ASC NULLS LAST, Field_Order__c ASC NULLS LAST
        ];
    }

    // -----------------------------------------------------------------
    // Field-level resolution (FLS enforcement lives here)
    // -----------------------------------------------------------------

    private static DynamicFormWrappers.FieldSchema resolveField(
        Form_Field_Configuration__c fc,
        Map<String, Schema.SObjectField> fieldMap
    ) {
        if (String.isBlank(fc.Field_API_Name__c)) {
            return null;
        }
        Schema.SObjectField sObjField = fieldMap.get(fc.Field_API_Name__c.toLowerCase());
        if (sObjField == null) {
            return null; // configured field no longer exists on the object - fail silently, not loudly, at render time
        }
        Schema.DescribeFieldResult dfr = sObjField.getDescribe();

        // --- FLS enforcement point #1: never render a field the user cannot see ---
        if (!dfr.isAccessible()) {
            return null;
        }

        DynamicFormWrappers.FieldSchema field = new DynamicFormWrappers.FieldSchema();
        field.apiName = fc.Field_API_Name__c;
        field.label = String.isNotBlank(fc.Field_Label__c) ? fc.Field_Label__c : dfr.getLabel();
        field.fieldOrder = fc.Field_Order__c != null ? Integer.valueOf(fc.Field_Order__c) : 0;
        field.helpText = fc.Help_Text__c;
        field.placeholder = fc.Input_Place_holder_Value__c;
        field.defaultValue = fc.Default_Value__c;
        field.validationPattern = fc.Validation_Pattern__c;
        field.validationError = fc.Validation_Error__c;
        field.conditionalRulesJson = fc.Conditional_Rules__c;
        field.required = (fc.Is_Required__c == true) || !dfr.isNillable();

        // --- FLS enforcement point #2: field renders read-only if the user
        // cannot create/update it, even if the admin didn't mark it Read Only ---
        Boolean userCanWrite = dfr.isCreateable() || dfr.isUpdateable();
        field.readOnly = (fc.Read_Only__c == true) || !userCanWrite;

        field.dataType = resolveDataType(fc.Field_Data_Type__c, dfr);

        if (field.dataType == 'Picklist' || field.dataType == 'Multi-Select Picklist') {
            field.options = resolvePicklistOptions(fc.Picklist_Values__c, dfr);
        }

        if (field.dataType == 'Lookup') {
            field.lookupObjectApiName = fc.Lookup_Object_API_Name__c;
            field.lookupDisplayField = String.isNotBlank(fc.Lookup_Display_Field__c) ? fc.Lookup_Display_Field__c : 'Name';
            field.lookupFilter = fc.Lookup_Filter__c;
        }

        return field;
    }

    /** Config override wins when populated; otherwise derive from the schema describe. */
    private static String resolveDataType(String configuredOverride, Schema.DescribeFieldResult dfr) {
        if (String.isNotBlank(configuredOverride)) {
            return configuredOverride;
        }
        Schema.DisplayType t = dfr.getType();
        if (t == Schema.DisplayType.PICKLIST) return 'Picklist';
        if (t == Schema.DisplayType.MULTIPICKLIST) return 'Multi-Select Picklist';
        if (t == Schema.DisplayType.BOOLEAN) return 'Checkbox';
        if (t == Schema.DisplayType.CURRENCY) return 'Currency';
        if (t == Schema.DisplayType.DATE) return 'Date';
        if (t == Schema.DisplayType.DATETIME) return 'DateTime';
        if (t == Schema.DisplayType.EMAIL) return 'Email';
        if (t == Schema.DisplayType.TEXTAREA) return 'Long Text Area';
        if (t == Schema.DisplayType.REFERENCE) return 'Lookup';
        if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.INTEGER || t == Schema.DisplayType.PERCENT) return 'Number';
        if (t == Schema.DisplayType.ADDRESS) return 'Address';
        return 'Text';
    }

    private static List<DynamicFormWrappers.PicklistOption> resolvePicklistOptions(
        String configuredOverride,
        Schema.DescribeFieldResult dfr
    ) {
        List<DynamicFormWrappers.PicklistOption> options = new List<DynamicFormWrappers.PicklistOption>();

        if (String.isNotBlank(configuredOverride)) {
            // Override format: one "Label|Value" pair per line.
            for (String line : configuredOverride.split('\n')) {
                if (String.isBlank(line)) continue;
                List<String> parts = line.split('\\|');
                String label = parts[0].trim();
                String value = parts.size() > 1 ? parts[1].trim() : label;
                options.add(new DynamicFormWrappers.PicklistOption(label, value));
            }
            return options;
        }

        for (Schema.PicklistEntry entry : dfr.getPicklistValues()) {
            if (entry.isActive()) {
                options.add(new DynamicFormWrappers.PicklistOption(entry.getLabel(), entry.getValue()));
            }
        }
        return options;
    }

    // -----------------------------------------------------------------
    // Record prefill (Update mode)
    // -----------------------------------------------------------------

    /**
     * Queries only the fields that already passed the FLS filter - never
     * queries a field that was excluded above, so a value can never leak
     * into the response for a field the user isn't allowed to see.
     */
    private static void prefillCurrentValues(
        String objectApiName,
        Id recordId,
        List<DynamicFormWrappers.FieldSchema> resolvedFields
    ) {
        Set<String> fieldNames = new Set<String>{'Id'};
        for (DynamicFormWrappers.FieldSchema f : resolvedFields) {
            // Address is a compound field - query its component parts instead of the compound name itself.
            if (f.dataType == 'Address') {
                for (String suffix : new List<String>{'Street', 'City', 'State', 'PostalCode', 'Country'}) {
                    fieldNames.add(f.apiName.removeEnd('Address') + suffix);
                }
            } else {
                fieldNames.add(f.apiName);
            }
        }

        String soql = 'SELECT ' + String.join(new List<String>(fieldNames), ', ') +
            ' FROM ' + objectApiName + ' WHERE Id = :recordId LIMIT 1';

        List<SObject> results;
        try {
            results = Database.query(soql, AccessLevel.USER_MODE);
        } catch (System.NoAccessException nae) {
            // User can see the fields individually but not this specific record
            // (sharing) - fail gracefully back to a blank Insert-style form.
            return;
        }
        if (results.isEmpty()) {
            return;
        }
        SObject record = results[0];

        for (DynamicFormWrappers.FieldSchema f : resolvedFields) {
            try {
                f.currentValue = record.get(f.apiName);
            } catch (Exception e) {
                // Compound (Address) fields aren't readable via get(apiName) directly;
                // leave currentValue null and let the LWC field-level inputs pull their
                // own component values if needed in a later iteration.
            }
        }
    }

    // -----------------------------------------------------------------
    // Small utilities
    // -----------------------------------------------------------------

    private static Set<String> splitMultiPicklist(String raw) {
        Set<String> result = new Set<String>();
        if (String.isNotBlank(raw)) {
            for (String v : raw.split(';')) {
                result.add(v.trim());
            }
        }
        return result;
    }
}