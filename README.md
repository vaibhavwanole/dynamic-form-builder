# Dynamic Form Builder

Metadata-driven, no-code form engine for Salesforce. Admins configure form structure, validation,
and multi-step workflows entirely through custom objects — the LWC engine renders a fully secure,
FLS-aware form for any object with zero deployment.

## Overview

The Dynamic Form Builder lets admins create, configure, and deploy fully functional data-capture
forms without writing code for each new use case. Two custom objects, `Form_Configuration__c` and
`Form_Field_Configuration__c`, define everything about a form: its target object, layout,
validation rules, and behavior. A Lightning Web Component engine reads that configuration at
runtime and dynamically renders the corresponding UI, supporting 13 field types including Lookup,
Multi-Select Picklist, and compound Address fields.

## Key capabilities

- **Metadata-driven rendering**: one engine serves any Salesforce object. Adding or changing a
  field is a data change, not a deployment.
- **Multi-object composite forms**: chains several object forms into a single guided, multi-step
  submission (e.g. Account to Contact to Opportunity), with configurable rollback-on-failure or
  resume-and-retry behavior.
- **Conditional logic**: field visibility and required-ness driven by simple JSON rules tied to
  other fields' values.
- **Enterprise-grade security**: every read and write enforces Salesforce's CRUD, Field-Level
  Security, and sharing rules via `USER_MODE`, matching the security model of native Salesforce
  forms rather than bypassing it.
- **Record-aware prefill**: placed on a record page, the form automatically detects a matching
  record and switches into edit mode with existing values pre-filled.
- **Built-in live preview**: admins can test and submit a form directly from its configuration
  record before rolling it out, with a one-click refresh to pull in the latest field changes.
- **Experience Cloud ready**: supports guest-user access to public-facing forms without exposing
  the underlying configuration data.
- **Design-time form picker**: a custom Dynamic Picklist in Lightning App Builder lets admins
  choose a form by name when placing the component, instead of pasting a record Id.

## What's included
## What's included

- **objects/**
  - `Form_Configuration__c/`: 16 custom fields + object definition
  - `Form_Field_Configuration__c/`: 22 custom fields + object definition
- **classes/**
  - `DynamicFormWrappers.cls`: shared DTO/wrapper classes
  - `DynamicFormSchemaService.cls`: schema resolution, FLS filtering, prefill
  - `DynamicFormSubmissionService.cls`: insert/update DML, composite orchestration
  - `FormConfigurationPicklist.cls`: Dynamic Picklist for the App Builder form picker
  - `DynamicFormSchemaServiceTest.cls`
  - `DynamicFormSubmissionServiceTest.cls`
- **lwc/**
  - `dynamicFormEngine/`: orchestrator, place this on a Record/App/Home page
  - `dynamicFormSection/`: renders one section (1 or 2 column layout)
  - `dynamicFormField/`: renders one input, for all 13 v1 data types
  - `dynamicFormPreview/`: place on the Form_Configuration__c record page, live-test before rollout
- **tabs/**: custom object tabs
- **applications/**: dedicated "Dynamic Form Builder" app
- **permissionsets/**
  - `Dynamic_Form_Builder_Admin.permissionset-meta.xml`

## Deploying to a Salesforce org

Using Salesforce CLI:

```bash
sf org login web --alias myDevOrg
sf project deploy start --source-dir force-app --target-org myDevOrg
sf org assign permset --name Dynamic_Form_Builder_Admin --target-org myDevOrg
```

Or deploy via VS Code with the Salesforce Extension Pack: right-click `force-app` → **SFDX: Deploy
Source to Org**.

After deployment:
1. Open the **Dynamic Form Builder** app from the App Launcher.
2. Create a `Form_Configuration__c` record (see field reference below), then its child
   `Form_Field_Configuration__c` records.
3. Open that config record and use the **Form Preview** component to test it live.
4. Add `dynamicFormEngine` to a Record/App/Home Page in App Builder, and pick your form from the
   "Form Configuration" dropdown.

## Architecture

- **DynamicFormSchemaService.getFormSchema(formConfigId, recordId)**: the single read entry
  point. Describes the target object, filters every field through `isAccessible()`, resolves data
  types and picklist options (config override, then schema fallback), and — when `recordId`'s
  object type matches the form's configured object and Update is supported — prefills current
  values via `WITH USER_MODE`, using only fields that already passed the FLS filter.
- **DynamicFormSubmissionService.submitForm / submitComposite**: the two write entry points.
  Every DML call uses `AccessLevel.USER_MODE` (CRUD, FLS, and sharing enforced together, matching
  `lightning-record-edit-form`'s effective security). Composite submissions run steps in
  `Step_Order__c` sequence, auto-populating each step's `Link_Field_API_Name__c` from the prior
  step's created Id, and either roll back the whole chain or keep successful steps committed on
  failure, per `Failure_Handling__c`.
- **LWC layer**: `dynamicFormEngine` owns all state (field values, conditional-rule evaluation,
  wizard step index). `dynamicFormSection` is pure layout. `dynamicFormField` is a pure
  input-rendering leaf with no knowledge of siblings. `dynamicFormPreview` reuses the
  section/field components and submits live, for real, so the config can be validated end to end
  before rollout.

## Field reference

### Form_Configuration__c

| API Name | Type | Description |
|---|---|---|
| Form_Display_Title__c | Text(255) | Title rendered at the top of the form for end users. |
| Object_API_Name__c | Text(255), required | API name of the target object this form creates/updates. |
| Is_Active__c | Checkbox | Controls whether this form is available for rendering. |
| Inactive_Reason__c | Text(255) | Optional note explaining a deactivation; informational only. |
| Insert_Button_Label__c | Text(255) | Submit button label in Insert mode. Defaults to "Submit". |
| Update_Button_Label__c | Text(255) | Submit button label in Update mode. Defaults to "Save". |
| Disable_Form_Validations__c | Checkbox | Skips required/pattern/conditional-rule checks. FLS is never skipped. |
| DML_Operations__c | Multi-Select (Insert;Update;Upsert;Delete) | Which operations this form supports. Delete is defined but not yet wired to a UI action (v2). |
| Success_Message_Insert__c | Text(255) | Message shown after a successful create. |
| Success_Message_Update__c | Text(255) | Message shown after a successful update. |
| Available_For_Guest_Users__c | Checkbox | Allows guest users to read this form's structure (never target data) via system mode. |
| Is_Composite__c | Checkbox | Marks this record as a multi-step composite master. |
| Parent_Form_Configuration__c | Lookup (self) | Links a step config to its composite master. |
| Step_Order__c | Number(2,0) | Sequence of this step within its composite form. |
| Link_Field_API_Name__c | Text(255) | Field to auto-populate with the previous step's created record Id. |
| Failure_Handling__c | Picklist (Rollback All Steps / Retry Failed Step Only) | Composite failure behavior. |

### Form_Field_Configuration__c

| API Name | Type | Description |
|---|---|---|
| Form_Configuration__c | Master-Detail | Parent form this field belongs to. |
| Field_API_Name__c | Text(255), required | API name of the target field. |
| Field_Label__c | Text(255) | Overrides the schema label when populated. |
| Field_Order__c | Number(18,0) | Order within its section. |
| Section_Name__c | Text(255) | Groups fields under a shared heading. |
| Section_Order__c | Number(18,0) | Order of this field's section on the form. |
| Section_Description__c | Text(255) | Optional text shown under the section heading. |
| Display_Layout__c | Picklist (1-Column / 2-Column) | Column layout for the section. |
| Is_Required__c | Checkbox | Marks the field required (in addition to schema-derived required-ness). |
| Is_Active__c | Checkbox | Controls whether this field renders. |
| Read_Only__c | Checkbox | Renders visible but non-editable. |
| Default_Value__c | Text(255) | Pre-filled value for new records. |
| Input_Place_holder_Value__c | Text(255) | Placeholder text. |
| Help_Text__c | Text(255) | Inline help/info icon text. |
| Validation_Pattern__c | Text(255) | Regex the value must match. |
| Validation_Error__c | Text(255) | Message shown when the pattern fails. |
| Field_Data_Type__c | Picklist (13 values) | Overrides the schema-derived data type. See below. |
| Picklist_Values__c | Long Text Area | Overrides schema picklist options; one `Label\|Value` per line. |
| Lookup_Object_API_Name__c | Text(255) | Target object for Lookup fields. |
| Lookup_Display_Field__c | Text(255) | Field shown in lookup search results (defaults to Name). |
| Lookup_Filter__c | Long Text Area | Optional SOQL WHERE-clause fragment for lookup filtering. |
| Conditional_Rules__c | Long Text Area (JSON) | Drives conditional visibility/required-ness. See below. |

**Field_Data_Type__c values (13 total):** Address, Checkbox, Currency, Date, DateTime, Email,
Long Text Area, Lookup, Multi-Select Picklist, Number, Picklist, Text, Password.

**Conditional_Rules__c JSON shape:**
```json
{ "controllingField": "BillingCountry", "operator": "equals", "value": "USA", "action": "require" }
```
`operator`: `equals` | `notEquals`. `action`: `require` | `hide` | `show`.

## Security model

- Every config always enforces CRUD, FLS, and sharing — there is no elevated bypass mode.
- Config records are read in `SYSTEM_MODE` only when `Available_For_Guest_Users__c` is checked,
  and only for structure — target-object data always goes through `USER_MODE`.
- A field the running user cannot see is never included in the schema, and is never queried during
  prefill.
- A field the user cannot create/update renders read-only regardless of what the client sends; the
  submission service re-checks this independently of the LWC.

## Known scope boundaries (v2 backlog)

- `Delete` is a defined DML operation but has no wired UI action yet.
- No server-side session/resume for "Retry Failed Step Only" — progress is held in LWC component
  state only; a page refresh mid-composite-form loses progress.
- `Lookup_Filter__c` is not yet applied to the `lightning-record-picker`'s search.
- No approval-process trigger, no external enrichment callouts, no persona-based config
  resolution.

## Testing

```bash
sf apex run test --class-names DynamicFormSchemaServiceTest,DynamicFormSubmissionServiceTest \
  --code-coverage --result-format human --target-org myDevOrg
```

## License

MIT — see [LICENSE](LICENSE).
