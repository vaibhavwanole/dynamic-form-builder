global class FormConfigurationPicklist extends VisualEditor.DynamicPickList {

    private VisualEditor.DesignTimePageContext context;

    global FormConfigurationPicklist(VisualEditor.DesignTimePageContext context) {
        this.context = context;
    }

    global override VisualEditor.DataRow getDefaultValue() {
        List<Form_Configuration__c> defaultConfig = [
            SELECT Id, Name, Form_Display_Title__c
            FROM Form_Configuration__c
            WHERE Is_Active__c = true AND Parent_Form_Configuration__c = null
            ORDER BY Name ASC
            LIMIT 1
        ];
        if (defaultConfig.isEmpty()) {
            return null;
        }
        return toDataRow(defaultConfig[0]);
    }

    global override VisualEditor.DynamicPickListRows getValues() {
        VisualEditor.DynamicPickListRows rows = new VisualEditor.DynamicPickListRows();
        for (Form_Configuration__c c : [
            SELECT Id, Name, Form_Display_Title__c
            FROM Form_Configuration__c
            WHERE Is_Active__c = true AND Parent_Form_Configuration__c = null
            ORDER BY Name ASC
        ]) {
            rows.addRow(toDataRow(c));
        }
        return rows;
    }

    /**
     * Builds a DataRow with an explicit String cast on the value - passing
     * an Id directly as the Object parameter has been unreliable in some
     * orgs and can surface as a generic "Invalid value" error in Builder
     * with the Id silently dropped. Label always falls back to the raw Id
     * string so a row is never created with a blank label either.
     */
    private static VisualEditor.DataRow toDataRow(Form_Configuration__c c) {
        String idAsString = String.valueOf(c.Id);
        String label = String.isNotBlank(c.Form_Display_Title__c)
            ? c.Form_Display_Title__c
            : (String.isNotBlank(c.Name) ? c.Name : idAsString);
        return new VisualEditor.DataRow(label, idAsString);
    }
}