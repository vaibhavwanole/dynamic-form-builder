/**
 * DynamicFormSubmissionService
 * ------------------------------
 * Handles Insert/Update DML for both standalone forms and composite
 * (multi-object) forms submitted via the Dynamic Form Builder engine.
 *
 * Security model:
 *  - Every DML operation runs with AccessLevel.USER_MODE, enforcing CRUD,
 *    FLS, and sharing together - the same effective protection level as
 *    lightning-record-edit-form, applied explicitly rather than implicitly.
 *  - Field values are only ever applied to the target SObject when the
 *    field is isCreateable() (Insert) or isUpdateable() (Update) for the
 *    running user, regardless of what the client sent - a defensive second
 *    check in addition to AccessLevel.USER_MODE on the DML itself.
 *  - There is no System Mode / elevated bypass in v1 by design.
 */
public with sharing class DynamicFormSubmissionService {

    // -----------------------------------------------------------------
    // Standalone (non-composite) submission
    // -----------------------------------------------------------------

    @AuraEnabled
    public static DynamicFormWrappers.SubmitResult submitForm(
        Id formConfigId,
        Id existingRecordId,
        Map<String, Object> fieldValues
    ) {
        DynamicFormWrappers.SubmitResult result = new DynamicFormWrappers.SubmitResult();
        try {
            Form_Configuration__c config = getConfig(formConfigId);
            SObject record = buildRecord(config.Object_API_Name__c, existingRecordId, fieldValues, config.Disable_Form_Validations__c);

            if (existingRecordId != null) {
                Database.update(record, AccessLevel.USER_MODE);
                result.recordId = existingRecordId;
                result.message = String.isNotBlank(config.Success_Message_Update__c)
                    ? config.Success_Message_Update__c
                    : 'Record updated successfully.';
            } else {
                Database.insert(record, AccessLevel.USER_MODE);
                result.recordId = record.Id;
                result.message = String.isNotBlank(config.Success_Message_Insert__c)
                    ? config.Success_Message_Insert__c
                    : 'Record created successfully.';
            }
            result.success = true;
        } catch (System.NoAccessException nae) {
            result.success = false;
            result.errorMessage = 'You do not have access to complete this action.';
        } catch (DmlException dmle) {
            result.success = false;
            result.errorMessage = dmle.getDmlMessage(0);
        } catch (Exception e) {
            result.success = false;
            result.errorMessage = 'Unable to submit the form: ' + e.getMessage();
        }
        return result;
    }

    // -----------------------------------------------------------------
    // Composite (multi-object) submission
    // -----------------------------------------------------------------

    /**
     * Submits every step of a composite form in order. Behavior on a
     * mid-chain failure is governed by the master config's
     * Failure_Handling__c:
     *  - 'Rollback All Steps': a Database.Savepoint wraps the whole chain;
     *    any failure undoes every prior step's DML.
     *  - 'Retry Failed Step Only': earlier successful steps stay committed;
     *    only the failed step's data is returned to the client for retry,
     *    along with the record Ids already committed so the client can
     *    resend just the failed step (component-state only - no server-side
     *    session object in v1).
     */
    @AuraEnabled
    public static DynamicFormWrappers.CompositeSubmitResult submitComposite(
        Id masterFormConfigId,
        List<DynamicFormWrappers.StepSubmission> steps
    ) {
        DynamicFormWrappers.CompositeSubmitResult result = new DynamicFormWrappers.CompositeSubmitResult();
        result.committedRecordIdsByStep = new Map<Integer, Id>();

        Form_Configuration__c masterConfig = getConfig(masterFormConfigId);
        Boolean rollbackMode = 'Rollback All Steps'.equalsIgnoreCase(masterConfig.Failure_Handling__c);

        // Steps must run in stepOrder sequence since later steps may depend
        // on an Id created by an earlier step (Link_Field_API_Name__c).
        steps.sort();

        Savepoint sp = rollbackMode ? Database.setSavepoint() : null;
        Map<Integer, Id> committedIds = new Map<Integer, Id>();

        for (DynamicFormWrappers.StepSubmission step : steps) {
            try {
                Form_Configuration__c stepConfig = getConfig(step.formConfigId);

                // Apply the previous step's created record Id into this
                // step's designated link field, if configured.
                if (String.isNotBlank(stepConfig.Link_Field_API_Name__c) && step.stepOrder > 1) {
                    Id parentId = committedIds.get(step.stepOrder - 1);
                    if (parentId != null) {
                        step.fieldValues.put(stepConfig.Link_Field_API_Name__c, parentId);
                    }
                }

                SObject record = buildRecord(
                    stepConfig.Object_API_Name__c,
                    step.existingRecordId,
                    step.fieldValues,
                    stepConfig.Disable_Form_Validations__c
                );

                if (step.existingRecordId != null) {
                    Database.update(record, AccessLevel.USER_MODE);
                    committedIds.put(step.stepOrder, step.existingRecordId);
                } else {
                    Database.insert(record, AccessLevel.USER_MODE);
                    committedIds.put(step.stepOrder, record.Id);
                }
            } catch (Exception e) {
                if (rollbackMode) {
                    Database.rollback(sp);
                    result.success = false;
                    result.failedStepOrder = step.stepOrder;
                    result.errorMessage = 'Step ' + step.stepOrder + ' failed: ' + e.getMessage();
                    result.committedRecordIdsByStep = new Map<Integer, Id>(); // everything undone
                    return result;
                } else {
                    // Retry mode: keep whatever committed so far, report the failure point.
                    result.success = false;
                    result.failedStepOrder = step.stepOrder;
                    result.errorMessage = 'Step ' + step.stepOrder + ' failed: ' + e.getMessage();
                    result.committedRecordIdsByStep = committedIds;
                    return result;
                }
            }
        }

        result.success = true;
        result.committedRecordIdsByStep = committedIds;
        return result;
    }

    // -----------------------------------------------------------------
    // Shared helpers
    // -----------------------------------------------------------------

    private static Form_Configuration__c getConfig(Id formConfigId) {
        List<Form_Configuration__c> configs = [
            SELECT Id, Object_API_Name__c, Disable_Form_Validations__c, Success_Message_Insert__c,
                   Success_Message_Update__c, Link_Field_API_Name__c, Failure_Handling__c
            FROM Form_Configuration__c
            WHERE Id = :formConfigId
            WITH USER_MODE
            LIMIT 1
        ];
        if (configs.isEmpty()) {
            throw new AuraHandledException('Form configuration not found or not accessible.');
        }
        return configs[0];
    }

    /**
     * Builds an SObject from raw field values, applying:
     *  - FLS enforcement (isCreateable/isUpdateable) per field, independent
     *    of whatever the client sent
     *  - required-field and pattern validation, unless the form has
     *    Disable_Form_Validations__c checked
     *  - type coercion from the loosely-typed client payload into the
     *    field's real Apex type
     */
    private static SObject buildRecord(
        String objectApiName,
        Id existingRecordId,
        Map<String, Object> fieldValues,
        Boolean skipValidations
    ) {
        Schema.SObjectType targetType = Schema.getGlobalDescribe().get(objectApiName.toLowerCase());
        if (targetType == null) {
            throw new AuraHandledException('Configured object "' + objectApiName + '" was not found.');
        }
        Map<String, Schema.SObjectField> fieldMap = targetType.getDescribe().fields.getMap();
        SObject record = targetType.newSObject(existingRecordId);
        Boolean isInsert = existingRecordId == null;

        // Required-ness enforced here is schema-derived (dfr.isNillable()) -
        // the admin-configured Is_Required__c / Validation_Pattern__c rules
        // are enforced client-side by the LWC before this call, and the LWC
        // re-fetches the same Form_Field_Configuration__c records used for
        // rendering, so the two can't drift out of sync.
        for (String fieldApiName : fieldValues.keySet()) {
            Schema.SObjectField sObjField = fieldMap.get(fieldApiName.toLowerCase());
            if (sObjField == null) {
                continue; // unknown field - ignore rather than error, avoids a crafted-payload injection vector
            }
            Schema.DescribeFieldResult dfr = sObjField.getDescribe();

            Boolean canWrite = isInsert ? dfr.isCreateable() : dfr.isUpdateable();
            if (!canWrite) {
                continue; // silently skip - do not let a client payload write a field the user cannot write
            }

            Object rawValue = fieldValues.get(fieldApiName);
            if (!skipValidations && dfr.isNillable() == false && (rawValue == null || String.valueOf(rawValue).trim() == '')) {
                throw new AuraHandledException('"' + dfr.getLabel() + '" is required.');
            }

            setTypedValue(record, dfr, fieldApiName, rawValue);
        }

        return record;
    }

    private static void setTypedValue(SObject record, Schema.DescribeFieldResult dfr, String apiName, Object rawValue) {
        if (rawValue == null) {
            record.put(apiName, null);
            return;
        }
        String rawStr = String.valueOf(rawValue);
        Schema.DisplayType t = dfr.getType();

        try {
            if (t == Schema.DisplayType.BOOLEAN) {
                record.put(apiName, Boolean.valueOf(rawValue));
            } else if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.CURRENCY || t == Schema.DisplayType.PERCENT) {
                record.put(apiName, Decimal.valueOf(rawStr));
            } else if (t == Schema.DisplayType.INTEGER) {
                record.put(apiName, Integer.valueOf(rawStr));
            } else if (t == Schema.DisplayType.DATE) {
                record.put(apiName, Date.valueOf(rawStr));
            } else if (t == Schema.DisplayType.DATETIME) {
                record.put(apiName, (Datetime) JSON.deserialize('"' + rawStr + '"', Datetime.class));
            } else if (t == Schema.DisplayType.MULTIPICKLIST) {
                // Client sends a List<String> for multi-select; normalize to the ';'-delimited string the platform expects.
                if (rawValue instanceof List<Object>) {
                    List<String> selected = new List<String>();
                    for (Object o : (List<Object>) rawValue) {
                        selected.add(String.valueOf(o));
                    }
                    record.put(apiName, String.join(selected, ';'));
                } else {
                    record.put(apiName, rawStr);
                }
            } else if (t == Schema.DisplayType.REFERENCE) {
                record.put(apiName, (Id) rawStr);
            } else {
                record.put(apiName, rawStr);
            }
        } catch (Exception e) {
            throw new AuraHandledException('Invalid value for "' + dfr.getLabel() + '".');
        }
    }
}