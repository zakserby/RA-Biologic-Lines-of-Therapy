***********************************************************************;
*******           Assign work directories                         ******;
*************************************************************************;
%LET dbuser=your_username;
FILENAME PWFILE "/path/to/your/pwd.txt";
** Uncomment And Run The Next Two Lines Only One Time Whenever You Change Your Password To Store The New Password**;
** PROC PWENCODE IN='your_password' OUT=pwfile;
** RUN; **;
** This Section Of Code Reads The Encrypted Password **;
DATA _NULL_;
  INFILE PWFILE TRUNCOVER;
  INPUT LINE :$100.;
  CALL SYMPUTX('dbpass',LINE);
RUN;


*** LIBNAME truven odbc datasrc=&YOUR_DSN schema=&cws;
** Setup Options And Variables **;
** Note New Data Source ODBC Entry Name For Impala DataWareHouse And **; 
** The Required Username/Password Requirement For Libname Statement  **;
OPTION NOTES MPRINT NOMLOGIC MINOPERATOR;
%LET team_schema = your_team_schema;
%LET dbuser = your_username;
%let my_prefix = Serby_;
%LET truven_com = marketscan_commercial;


** Note New Data Source ODBC Entry Name For Impala DataWareHouse And **; 
** The Required Username/Password Requirement For Libname Statement  **;
LIBNAME derived odbc datasrc=YOUR_DSN USER="&dbuser" PASS="&dbpass" schema=&team_schema.;
LIBNAME data odbc datasrc=YOUR_DSN USER="&dbuser" PASS="&dbpass" schema=&truven_com.;

%LET imp_lib=&team_schema..&my_prefix.;
%LET sas_lib=derived.&my_prefix.;

%GLOBAL open_close;
%LET open_close=0;


***Database selection;
%let truven_com=marketscan_commercial;
%let truven_care=marketscan_medicare;
%let drug = %str(upadacitinib);
%let drug_opp = %str(upadacitinib);
%let upadacitinib = %str('00074104328', '00074230630', '00074230670', '00074231030');


*******************************************************************************;
*                      STEP 1                                                 *;
*******************************************************************************;

** 1) Finding UPA Rx in ID Window**;
proc sql;
  connect to odbc as impala (datasrc="YOUR_DSN" user="&dbuser" pass="&dbpass"); 
  ** Drop the existing table if it exists **;
  execute (drop table if exists &imp_lib.vx_clm purge) by impala;
  ** Create a new table and populate it with data from two sources **;
  execute (create table if not exists &imp_lib.vx_clm stored as parquet as
            select enrolid, svcdate, ndcnum
              from &truven_com..outpatient_drug_claims 
             where svcdate >= '2019-08-16' and 
                   ndcnum in(&upadacitinib)
            union all
            select enrolid, svcdate, ndcnum
              from &truven_care..outpatient_drug_claims 
             where svcdate >= '2019-08-16' and 
                   ndcnum in(&upadacitinib)
          ) by impala;
  execute (invalidate metadata &imp_lib.vx_clm) by impala;
  ** Compute statistics for the new table **;
  execute (compute stats &imp_lib.vx_clm) by impala;
  ** Select and display table statistics **;
  select * from connection to impala(show table stats &imp_lib.vx_clm);
  disconnect from impala;
quit;


**counts the number of unique enrolid values in the my_prefix.vx_clm table and stores the count in the macro variable td**;
proc sql;
  select count(distinct enrolid) into: td
   from derived.&my_prefix.vx_clm;
quit;


**The second block finds the latest (maximum) service date (svcdate) in the my_prefix.vx_clm table and stores this date in the macro variable maxdate**;
proc sql;
  select max(svcdate) into: maxdate
   from derived.&my_prefix.vx_clm;
quit;
/* 6/30/2023 */
/* count removed */


** Find index date and index drug **;
proc sql;
  connect to odbc as impala (datasrc="YOUR_DSN" user="&dbuser" pass="&dbpass");
      execute (drop table if exists &imp_lib.vx_pat purge) by impala;
      execute (create table if not exists &imp_lib.vx_pat stored as parquet as
                select enrolid, min(svcdate) as index_date
                 from &imp_lib.vx_clm group by enrolid) by impala;
      execute (invalidate metadata &imp_lib.vx_pat) by impala;
      execute (compute stats &imp_lib.vx_pat) by impala;
      select * from connection to impala(show table stats &imp_lib.vx_pat);
  disconnect from impala;
quit;


** 2) Patients with 12 months continuous baseline enrollment and 12 month after the index date**;
proc sql;
   connect to odbc as impala (datasrc="YOUR_DSN" user="&dbuser" pass="&dbpass");
       execute (drop table if exists &imp_lib.vx_pre_post purge) by impala;
       execute (create table if not exists  &imp_lib.vx_pre_post as
                select a.*, b.gender, b.dobyr, b.dtstart, b.dtend, datediff(a.index_date, b.dtstart) as pre_flup,
                            datediff(b.dtend, a.index_date) as post_flup
                 from &imp_lib.vx_pat a, 
                           &truven_com..enrollment as b
                                                        
                  where a.enrolid = b.enrolid and
                              datediff(a.index_date, b.dtstart) >= 365 and 
                             datediff(b.dtend, a.index_date) >= 365) by impala;
        execute (invalidate metadata  &imp_lib.vx_pre_post) by impala;
        execute (compute stats  &imp_lib.vx_pre_post) by impala;
        select * from connection to impala(select count(1) from  &imp_lib.vx_pre_post);
   disconnect from impala;
quit;
/* count removed */


** Count the number of Enrollees**;
proc sql;
  select count(distinct enrolid) into: td
   from derived.&my_prefix.vx_pre_post;
quit;


** 3) No UPA drug in the 12 month baseline period **;
proc sql;
  connect to odbc as impala (datasrc="YOUR_DSN" user="&dbuser" pass="&dbpass");
      execute (drop table if exists &imp_lib.vx_no_upa) by impala;
      execute (create table if not exists &imp_lib.vx_no_upa stored as parquet as
                select a.*, b.index_date, b.gender as gender_b, b.dobyr as dobyr_b, b.dtstart as dtstart_b, b.dtend as dtend_b, 
                       datediff(b.index_date, b.dtstart) as pre_flup_b, datediff(b.dtend, b.index_date) as post_flup_b
                from &truven_com..outpatient_drug_claims as a, &imp_lib.vx_pre_post as b
                where a.enrolid = b.enrolid and
                      datediff(b.index_date, a.svcdate) <= 365 and
                      datediff(b.index_date, a.svcdate) > 0 and
                      a.ndcnum not in (&upadacitinib)
            union all        
                select a.*, b.index_date, b.gender as gender_b, b.dobyr as dobyr_b, b.dtstart as dtstart_b, b.dtend as dtend_b, 
                       datediff(b.index_date, b.dtstart) as pre_flup_b, datediff(b.dtend, b.index_date) as post_flup_b
                from &truven_care..outpatient_drug_claims as a, &imp_lib.vx_pre_post as b
                where a.enrolid = b.enrolid and
                      datediff(b.index_date, a.svcdate) <= 365 and
                      datediff(b.index_date, a.svcdate) > 0 and
                      a.ndcnum not in (&upadacitinib)
                ) by impala;   
      execute (invalidate metadata &imp_lib.vx_no_upa) by impala;
      execute (compute stats &imp_lib.vx_no_upa) by impala;
      select * from connection to impala(show table stats &imp_lib.vx_no_upa);
  disconnect from impala;
quit;


proc sql;
  select count(distinct enrolid) into: td
   from derived.&my_prefix.vx_no_upa;
quit;
/* n(td)=count removed */


** 4) age >=18 at index date **;
proc sql;
  connect to odbc as impala (datasrc="YOUR_DSN" user="&dbuser" pass="&dbpass");
  execute (drop table if exists &imp_lib.vx_pre_post18 purge) by impala;
  execute (create table if not exists &imp_lib.vx_pre_post18 as
           select *
           from &imp_lib.vx_no_upa
           where year(index_date) - dobyr_b >= 18 ) by impala;
  execute (invalidate metadata &imp_lib.vx_pre_post18) by impala;
  execute (compute stats &imp_lib.vx_pre_post18) by impala;
  select * from connection to impala(
    select count(distinct enrolid) as distinct_patient_count_after_age_filter
    from &imp_lib.vx_pre_post18
  );
  disconnect from impala;
quit;
/* n(td)=count removed */


** Exclusion criteria, steps to implement exclusion criteria: RA in baseline**;

** Medical claims in the follow up period **;
**join id if back to outpatient service in the baseline period**;
proc sql;
  connect to odbc as impala (datasrc="YOUR_DSN" user="&dbuser" pass="&dbpass");
      execute (drop table if exists &imp_lib.vx_out) by impala;
      execute (create table if not exists &imp_lib.vx_out stored as parquet as
                select  a.*, b.index_date
                from &truven_com..outpatient_services as a, &imp_lib.vx_pre_post18 as b
                where a.enrolid = b.enrolid and 
                datediff(b.index_date, a.svcdate) <= 365 and  datediff(b.index_date, a.svcdate) >= 0 
            union all        
                select  a.*, b.index_date
                from &truven_care..outpatient_services as a, &imp_lib.vx_pre_post18 as b
                where a.enrolid = b.enrolid and 
                datediff(b.index_date, a.svcdate) <= 365 and  datediff(b.index_date, a.svcdate) >= 0) by impala;   
                execute (invalidate metadata &imp_lib.vx_out) by impala;
      execute (compute stats  &imp_lib.vx_out) by impala;
      select * from connection to impala(show table stats &imp_lib.vx_out);
  disconnect from impala;
quit;         

    
**join id if back to inpatient service in the baseline up period**;      
        proc sql;
  connect to odbc as impala (datasrc="YOUR_DSN" user="&dbuser" pass="&dbpass");
      execute (drop table if exists &imp_lib.vx_in) by impala;
      execute (create table if not exists &imp_lib.vx_in stored as parquet as
                select  a.*, b.index_date
                from &truven_com..inpatient_services as a, &imp_lib.vx_pre_post18 as b
                where a.enrolid = b.enrolid and 
                datediff(b.index_date, a.svcdate) <= 365 and  datediff(b.index_date, a.svcdate) >= 0 
            union all        
                select  a.*, b.index_date
                from &truven_care..inpatient_services as a, &imp_lib.vx_pre_post18 as b
                where a.enrolid = b.enrolid and 
                datediff(b.index_date, a.svcdate) <= 365 and  datediff(b.index_date, a.svcdate) >= 0) by impala;   
         execute (invalidate metadata &imp_lib.vx_in) by impala;
      execute (compute stats  &imp_lib.vx_in) by impala;
      select * from connection to impala(show table stats &imp_lib.vx_in);
  disconnect from impala;
quit;         

       
** Combine outpatient and inpatient service together **;
proc sql;
  connect to odbc as impala (datasrc="YOUR_DSN" user="&dbuser" pass="&dbpass");
      execute (drop table if exists  &imp_lib.vx_in_out) by impala;
      execute (create table if not exists &imp_lib.vx_in_out stored as parquet as
                select  enrolid, DX1, DX2, DX3, DX4, DX5, ' ' as PDX, PROC1, ' ' as PPROC, SVCDATE, SEX, Age,
                        0 as loc, ' ' as admdate, ' ' as disdate, plantyp, stdplac, index_date
                from  &imp_lib.vx_out
                union all     
                select  enrolid, DX1, DX2, DX3, DX4, DX5, PDX, PROC1, PPROC, SVCDATE, SEX, Age, 
                        1 as loc, admdate, disdate, plantyp, stdplac, index_date
                from &imp_lib.vx_in ) by impala;
      execute (invalidate metadata  &imp_lib.vx_in_out) by impala;
      execute (compute stats &imp_lib.vx_in_out) by impala;
      select * from connection to impala(show table stats &imp_lib.vx_in_out);
  disconnect from impala;
quit;


***************************
****** RA ICD Codes *******
***************************;

%let icd='^(7140|7141|7142|71481|M05|M06).*';

** 5) RA during the baseline period  **;
proc sql;
  connect to odbc as impala (datasrc="YOUR_DSN" user="&dbuser" pass="&dbpass");
      execute (drop table if exists &imp_lib.ra_clm  purge) by impala;
      execute (create table if not exists &imp_lib.ra_clm stored as parquet as
                select *
                 from &imp_lib.vx_in_out
                  where regexp_like(DX1, &icd) or regexp_like(DX2, &icd) or 
                        regexp_like(DX3, &icd) or regexp_like(DX4, &icd) or 
                        regexp_like(DX5, &icd)
					) by impala;
      execute (invalidate metadata  &imp_lib.ra_clm) by impala;
      execute (compute stats  &imp_lib.ra_clm) by impala;
      select * from connection to impala(show table stats &imp_lib.ra_clm);
  disconnect from impala;
quit;
/* n(ra)=count removed */


proc sql;
  select count(distinct enrolid) into: td
   from derived.&my_prefix.ra_clm;
quit;


********************************************
*** Final cohort patient size is N=[removed] ****
********************************************;


***biologic dmard and jak***;
%let bio_dmard_and_jak='abatacept|certolizumab|infliximab|adalimumab|rituximab|anakinra|etanercept|tocilizumab|golimumab|sarilumab|tofacitinib|baricitinib|upadacitinib';

** 6) Any drug in the 12 month followup rx **;
      proc sql;
  connect to odbc as impala (datasrc="YOUR_DSN" user="&dbuser" pass="&dbpass");
      execute (drop table if exists &imp_lib.vx_treat_seq) by impala;
      execute (create table if not exists &imp_lib.vx_treat_seq stored as parquet as
                select distinct a.svcdate, b.index_date, a.age, a.sex, a.enrolid, a.ndcnum
                from &truven_com..outpatient_drug_claims as a, &imp_lib.ra_clm as b
                where a.enrolid = b.enrolid and
               datediff (b.index_date, a.svcdate) <= 0 and  datediff(b.index_date, a.svcdate) >-365
                and a.ndcnum in (select distinct ndcnum from &truven_com..redbook where regexp_like(gennme, &bio_dmard_and_jak, 'i'))   
					 union all        
               select distinct a.svcdate, b.index_date, a.age, a.sex, a.enrolid, a.ndcnum
                from &truven_care..outpatient_drug_claims  as a, &imp_lib.ra_clm as b
                where a.enrolid = b.enrolid and
              datediff(b.index_date, a.svcdate) <= 0  and  datediff(b.index_date, a.svcdate) >-365
              and a.ndcnum in (select distinct ndcnum from &truven_care..redbook where regexp_like(gennme, &bio_dmard_and_jak, 'i'))
  				) by impala;   
                execute (invalidate metadata &imp_lib.vx_treat_seq) by impala;
      execute (compute stats  &imp_lib.vx_treat_seq) by impala;
      select * from connection to impala(show table stats &imp_lib.vx_treat_seq);
  disconnect from impala;
quit;    
/* count removed */


proc sql;
  select count(distinct enrolid) into: td
   from derived.&my_prefix.vx_treat_seq;
quit;
/* n(td)=count removed */


** 7) Filtering for distinct patients **;
proc sql;
  connect to odbc as impala (datasrc="YOUR_DSN" user="&dbuser" pass="&dbpass");
      execute (drop table if exists &imp_lib.vx_distinct) by impala;
      execute (create table if not exists &imp_lib.vx_distinct stored as parquet as
                select distinct index_date, sex, enrolid, ndcnum
                from &imp_lib.vx_treat_seq
				order by enrolid
  				) by impala;   
      execute (invalidate metadata &imp_lib.vx_distinct) by impala;
      execute (compute stats &imp_lib.vx_distinct) by impala;
      select * from connection to impala(show table stats &imp_lib.vx_distinct);
  disconnect from impala;
quit;
   

***biologic dmard and jak***;
%let bio_dmard_and_jak='abatacept|certolizumab|infliximab|adalimumab|rituximab|anakinra|etanercept|tocilizumab|golimumab|sarilumab|tofacitinib|baricitinib|upadacitinib';

** 8) Replace ndcnum with generic name in table, coalesce function handles 
all null values and if not null will use that value or character string in this case **;
proc sql;
    connect to odbc as impala (datasrc="YOUR_DSN" user="&dbuser" pass="&dbpass");
    execute (drop table if exists &imp_lib.vx_gennme) by impala;
    execute (create table if not exists &imp_lib.vx_gennme stored as parquet as
                select distinct b.index_date, coalesce(a.gennme, c.gennme) as gennme, b.sex, b.enrolid, b.ndcnum
                from &imp_lib.vx_distinct as b
                left join (select ndcnum, gennme 
                           from &truven_com..redbook 
                           where regexp_like(gennme, &bio_dmard_and_jak, 'i')) as a
                on a.ndcnum = b.ndcnum
                left join (select ndcnum, gennme 
                           from &truven_care..redbook 
                           where regexp_like(gennme, &bio_dmard_and_jak, 'i')) as c
                on c.ndcnum = b.ndcnum
            ) by impala;   
    execute (invalidate metadata &imp_lib.vx_gennme) by impala;
    execute (compute stats &imp_lib.vx_gennme) by impala;
    select * from connection to impala (show table stats &imp_lib.vx_gennme);
    disconnect from impala;
quit;


** Define the library reference for RA_Upa folder **;
LIBNAME RA_Upa '/path/to/your/RA_Upa/code';

** 9) Proc Transpose for Reformatting final cohort table from &imp_lib.vx_treat_seq into wide format **;
proc transpose data=derived.&my_prefix.vx_gennme out=transposed_table prefix=med_;
  by enrolid index_date; * Add variables you want to retain as IDs *;
  var gennme; * Specify the variable you want to transpose *;
run;


** 10) Final revisions of proc transpose table before exporting **;
** Modifying medications in med_1 and med_2 **;
data transposed_table;
  set transposed_table;
  if med_2 = 'Infliximab-dyyb' then med_2 = 'Infliximab';
  if med_2 = 'riTUXimab-pvvr' then med_2 = 'Rituximab';
run;

** Checking frequency of transposed_table (step is not necessary) **;
proc freq data = transposed_table;
 table med_1 med_2 med_3 med_4 med_5 med_6;
run;

** Reducing medications to 4 aka ending with the final table **;
data RA_Upa.final_table; 
 set transposed_table;
 keep enrolid index_date med_1 med_2 med_3 med_4;
run;