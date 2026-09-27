# RA Biologic Lines of Therapy

SAS and R code from a summer 2024 internship project on lines of therapy for biologic DMARDs and JAK inhibitors in rheumatoid arthritis (RA) patients who started upadacitinib. The SAS code builds the patient cohort from MarketScan claims data, and the R code turns each patient's treatment sequence into Sankey diagrams and an interactive R Shiny app.

There is no real patient data in this repository and nothing links to the actual data. The code files are the original code with only these changes: the username, password, data source, schema names, an internal table name and file paths are replaced with placeholders (your_username, your_password, YOUR_DSN, your_team_schema, enrollment, /path/to/your/), a colleague's name is removed from one document title, and the patient counts in the SAS comments are replaced with "count removed".

SAS code:
- SAS Code Baseline RA Patient Export Code.sas : cohort code for the baseline export
- SAS Code Follow Up RA Patients Export Code.sas : cohort code for the follow-up export
- both files run the same steps (the baseline file's frequency check also includes med_6):
  - step 1 finds upadacitinib prescriptions (by NDC code) from 8/16/2019 on and takes each patient's first one as the index date
  - step 2 keeps patients with 12 months of continuous enrollment before and after the index date
  - step 3 keeps patients with no upadacitinib in the 12 month baseline period
  - step 4 keeps patients 18 or older at the index date
  - step 5 keeps patients with an RA diagnosis (ICD-9 714.0-714.2, 714.81 or ICD-10 M05, M06) on an inpatient or outpatient claim in the baseline period
  - step 6 pulls every biologic DMARD and JAK inhibitor claim in the 12 months after the index date
  - steps 7-8 keep the distinct drugs for each patient and swap NDC codes for generic names
  - steps 9-10 transpose to one row per patient and keep enrolid, index_date and med_1 to med_4

R code:
- R Code for Sankey Diagram.Rmd : reads the SAS output table and draws Sankey diagrams of the lines of therapy, one with networkD3 (zoomable) and one with plotly (hovering shows incoming and outgoing counts and percentages)
- R Shiny Application Biologic Lines of Therapy for RA Patients.Rmd : reads the baseline and follow-up SAS output tables, saves them as Excel files, and runs an R Shiny app with four tabs
  - Title Page lists the biologics by drug class
  - Baseline and Follow Up each have a Sankey diagram, a pie chart and a medication count table, plus options to remove treatment stages or specific drugs
  - Index Year Chart shows medication counts by index year

Example data (made up):
- baseline_dataset.xlsx : fake baseline table (fake IDs, dates and drug sequences) in the same format as the real export (enrolid, index_date, med_1 to med_4)
- followup_dataset.xlsx : fake follow-up table in the same format

To run: the SAS code needs access to MarketScan; fill in the placeholders first. The R code reads the SAS output tables (.sas7bdat); change the /path/to/your/ paths to your files. Packages: haven, dplyr, tidyr, plotly, shiny, lubridate, DT, writexl, networkD3, ggplot2 and pander.
