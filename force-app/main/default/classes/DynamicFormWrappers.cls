/**
 * DynamicFormWrappers
 * --------------------
 * Plain data-transfer classes shared between DynamicFormSchemaService and
 * DynamicFormSubmissionService, and serialized to/from the LWC layer.
 *
 * Kept dependency-free (no SOQL/DML here) so they can be unit tested in
 * isolation and reused across both services without creating a circular
 * class dependency.
 */
public with sharing class DynamicFormWrappers {

    /** Full schema for a single (non-composite) form, ready for the LWC to render. */
    public class FormSchema {
        @AuraEnabled public Id formConfigId;
        @AuraEnabled public String formTitle;
        @AuraEnabled public String objectApiName;
        @AuraEnabled public String mode;                 // 'Insert' or 'Update'
        @AuraEnabled public String insertButtonLabel;
        @AuraEnabled public String updateButtonLabel;
        @AuraEnabled public String successMessageInsert;
        @AuraEnabled public String successMessageUpdate;
        @AuraEnabled public Boolean disableValidations;
        @AuraEnabled public Boolean isComposite;
        @AuraEnabled public String failureHandling;       // 'Rollback All Steps' or 'Retry Failed Step Only'
        @AuraEnabled public Id recordId;                  // populated when prefilled from an existing record
        @AuraEnabled public List<SectionSchema> sections;
        @AuraEnabled public List<CompositeStep> compositeSteps; // populated only when isComposite = true
    }

    /** One step of a composite (multi-object) form. */
    public class CompositeStep implements Comparable {
        @AuraEnabled public Id formConfigId;
        @AuraEnabled public Integer stepOrder;
        @AuraEnabled public String objectApiName;
        @AuraEnabled public String linkFieldApiName;
        @AuraEnabled public FormSchema stepSchema;

        public Integer compareTo(Object other) {
            CompositeStep o = (CompositeStep) other;
            Integer mine = stepOrder == null ? 0 : stepOrder;
            Integer theirs = o.stepOrder == null ? 0 : o.stepOrder;
            return mine - theirs;
        }
    }

    /** One rendered section, grouping an ordered list of fields. */
    public class SectionSchema implements Comparable {
        @AuraEnabled public String sectionName;
        @AuraEnabled public String sectionDescription;
        @AuraEnabled public Integer sectionOrder;
        @AuraEnabled public String displayLayout; // '1-Column' or '2-Column'
        @AuraEnabled public List<FieldSchema> fields;

        public Integer compareTo(Object other) {
            SectionSchema o = (SectionSchema) other;
            Integer mine = sectionOrder == null ? 0 : sectionOrder;
            Integer theirs = o.sectionOrder == null ? 0 : o.sectionOrder;
            return mine - theirs;
        }
    }

    /** One rendered field, fully resolved (schema-derived, with config overrides applied). */
    public class FieldSchema implements Comparable {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public String dataType;      // resolved value from the 13-type set
        @AuraEnabled public Boolean required;
        @AuraEnabled public Boolean readOnly;
        @AuraEnabled public Integer fieldOrder;
        @AuraEnabled public String helpText;
        @AuraEnabled public String placeholder;
        @AuraEnabled public String defaultValue;
        @AuraEnabled public Object currentValue;  // populated during prefill (Update mode)
        @AuraEnabled public String validationPattern;
        @AuraEnabled public String validationError;
        @AuraEnabled public String conditionalRulesJson;
        @AuraEnabled public List<PicklistOption> options;      // Picklist / Multi-Select Picklist
        @AuraEnabled public String lookupObjectApiName;         // Lookup only
        @AuraEnabled public String lookupDisplayField;          // Lookup only
        @AuraEnabled public String lookupFilter;                // Lookup only

        public Integer compareTo(Object other) {
            FieldSchema o = (FieldSchema) other;
            Integer mine = fieldOrder == null ? 0 : fieldOrder;
            Integer theirs = o.fieldOrder == null ? 0 : o.fieldOrder;
            return mine - theirs;
        }
    }

    public class PicklistOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        public PicklistOption(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    /** Result of submitting a single (non-composite) form, or a single composite step. */
    public class SubmitResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Id recordId;
        @AuraEnabled public String message;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public Integer failedStepOrder; // populated only on a composite failure
    }

    /** Input payload for one step of a composite submission. */
    public class StepSubmission implements Comparable {
        @AuraEnabled public Id formConfigId;
        @AuraEnabled public Integer stepOrder;
        @AuraEnabled public Id existingRecordId;         // populated when this step is itself an Update
        @AuraEnabled public Map<String, Object> fieldValues;

        public Integer compareTo(Object other) {
            StepSubmission o = (StepSubmission) other;
            Integer mine = stepOrder == null ? 0 : stepOrder;
            Integer theirs = o.stepOrder == null ? 0 : o.stepOrder;
            return mine - theirs;
        }
    }

    /** Result of a full composite submission (all steps). */
    public class CompositeSubmitResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public Integer failedStepOrder;
        @AuraEnabled public Map<Integer, Id> committedRecordIdsByStep; // for Retry mode: what's already saved
    }
}