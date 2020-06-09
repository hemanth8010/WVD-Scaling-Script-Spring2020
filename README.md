This is a stop-gap solution for Spring 2020 release based on the scaling script built for the Fall 2019 WVD release.  

Follow the guidance below for entering the appropriate parameters for your scenario.

Copy the commands from Deployment helper script in this repo into PowerShell ISE(Administrator mode) on your workstation and run them in order. Do not run all at once as there is a manual step required to create a run-as account in the Automation Account that will be created.

This scaledeployment script will create the auto scale script execution required resources in Microsoft Azure. Resources are 
- Azure Automation Account
- Automation Account Runbook and publish the basic scale script. 
- Automation Account Webhook and store the WebhookURI in Azure Automation Account Variable.
- Log Analytic Workspace Custom Tables and Field Names.
- Azure LogicApp Scheduler.


Note: Try at your own risk. 