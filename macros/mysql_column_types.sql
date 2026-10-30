{#
    care2's MySQL column types, for every column Airbyte lands as something else:
    the list mysql_types_replace() casts every source's raw_access back to. Read
    macros/mysql_types.sql for why, for what is deliberately not cast, and for what
    applying care2's schema to the other sources risks.

    SHAPE: TABLE -> target type -> [COLUMNS], every name as Snowflake spells it
    (the physical table, upper case). Only integer, decimal and (var)char columns
    appear, and only where Airbyte's type differs:
        tinyint -> number(3,0)    smallint -> number(5,0)    int -> number(10,0)
        bigint -> number(19,0)    decimal(p,s) -> number(p,s)
        varchar(n) / char(n) -> varchar(n)
    The (11) in int(11) is a display width, not a precision. The mapping also holds
    for unsigned columns, except bigint unsigned, which needs number(20,0).
    tinyint(1) is the exception: Airbyte lands it as BOOLEAN, so it is not listed.

    LEFT OUT ON PURPOSE, because other sources declare them wider than care2 and
    hold values that would not fit (checked against every source's data,
    2026-10-09): STATUSPICK.NOTE (varchar(250) in care2, up to 11,466 chars
    elsewhere) and CMFORMQUESTIONANSWERS.ANSWER (varchar(300), up to 775). They
    stay VARCHAR in every source.

    WIDENED ON PURPOSE: CONTACTS.COUNTY is varchar(60) in care2, but R1 care1 holds
    a 70-character value, so it is listed as varchar(100) for every source
    (2026-10-12). care2's packages see DT_STR(100) for it, not DT_STR(60).

    GENERATED 2026-10-09 from a column-by-column comparison of care2's MySQL schema
    with ANALYTICS_RAW_ACCESS.CARE2 on the R2 account. Eight tables had no view yet
    (cmCarerBank, cmContractSettings, cmExpenses, cmExpensesType,
    cmQualificationsArchive, holidaysStartingBalance, permissionsCarer,
    updatedField), so their entries come from MySQL alone; the class check in
    mysql_types_replace() skips any that Airbyte delivers as something unexpected.

    THE RC* TABLES, PREFERREDCARERS, CMCOMPANYBILLINGPICK AND CONTACTTYPE ARE THE
    EXCEPTION: INFERRED, NOT READ FROM MYSQL. None of them is in care2's schema, and
    no MySQL schema of a source that has them has been read yet. Their entries list
    every integer column Airbyte lands as NUMBER(38,0), all as number(10,0): 1,481 of
    care2's 1,491 integer columns are int(N), and every value checked fits in 10
    digits — R1 care4 and R2 care2, care3, care5 and beta in full, and in R1 care1
    PREFERREDCARERS, CMCOMPANYBILLINGPICK and CONTACTTYPE (2026-10-12; care1's
    handful of rc* rows were not checked). A column that is really tinyint or
    smallint comes out wider than MySQL, which is harmless; one that is really bigint
    fails once a value passes 10 digits. Their strings are not listed and stay
    VARCHAR, since no varchar(n) length can be read from the data (PREFERREDCARERS
    has none). Replace these entries from information_schema once a source's MySQL
    schema is available.

    CMSKINASSESSMENTS IS INFERRED THE SAME WAY. It reached Snowflake on 2026-10-15,
    after the 2026-10-09 comparison, so its MySQL types were never read; every value
    in R2 care2, care3, care5 and beta fits in 10 digits (2026-10-28).

    TO UPDATE, edit by hand from information_schema.columns.column_type in care2's
    MySQL, with the mapping above. No Jinja comment inside the dict: it breaks the
    expression, and every raw_access model with it.
#}

{% macro mysql_column_types() %}
    {{ return({
        'ADMINNOTES': {
            'number(10,0)': ['ID', 'CREATEDBY', 'SCHEDULEID', 'TIMESHEETID', 'CARERID', 'CLIENTID',
                'COMPANYID', 'LOCATIONID', 'SEENBY', 'IMPORTANT', 'SIGNID', 'DELETEDBY'],
            'varchar(10)': ['NOTEFOR'],
            'varchar(20)': ['NOTEADDED'],
            'varchar(100)': ['SIGNNAME']
        },
        'AREA': {
            'number(10,0)': ['ID', 'COMPANYID', 'LOCATIONID', 'BRANCHID', 'CREATEDBY', 'DELETEDBY',
                'UPDATEDBY', 'WARDFLAG', 'CAREHOMEFLAG', 'NHFLAG'],
            'varchar(100)': ['SAGEAREAID', 'ODSCODE'],
            'varchar(200)': ['NAME', 'CONTACTNAME', 'CONTACTADDRESS', 'CONTACTPHONE']
        },
        'ASSESSMENT': {
            'number(10,0)': ['ID', 'DELETEDBY', 'CLIENTID', 'COMPANYID', 'LOCATIONID',
                'ASSESSMENTID', 'ASSIGNTOCARER', 'OUTCOMEID', 'CREATEDBY'],
            'varchar(100)': ['NAME']
        },
        'ASSESSMENTHISTORY': {
            'number(10,0)': ['ID', 'ASSESSID', 'CLIENTID', 'UPDATEDBY', 'ASSESSBY', 'COMPANYID',
                'LOCATIONID', 'OUTCOMEID', 'DELETEDBY']
        },
        'ASSESSMENTTYPE': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID',
                'DEFAULTASSESSMENT'],
            'varchar(10)': ['COLOUR'],
            'varchar(20)': ['DEFAULTLENGTH'],
            'varchar(50)': ['NAME'],
            'varchar(250)': ['OUTCOMEIDS']
        },
        'BANKHOLIDAYPERSONALISED': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'CARERPAY', 'CLIENTBILLING', 'SCHEDULEDISPLAY', 'AREAID'],
            'varchar(20)': ['DAYINCREASEPERCENT'],
            'varchar(200)': ['HOLIDAY', 'TYPE']
        },
        'BANKHOLIDAYPERSONALISEDAREA': {
            'number(10,0)': ['ID', 'BANKHOLIDAYID', 'AREAID', 'COMPANYID', 'LOCATIONID',
                'CREATEDBY', 'UPDATEDBY', 'DELETEDBY']
        },
        'CARER': {
            'number(10,0)': ['ID', 'STATE', 'TRANSPORTTYPE', 'SCHEDULE', 'AREA', 'POSITION',
                'LOCATION', 'VIEWPRIVATENOTE', 'PERMISSIONID', 'LEVELID', 'CUSTOMACCESS', 'SMS',
                'COMPANYID', 'PRIVATENOTE', 'BLACKLIST', 'NURSE', 'FINANCENO', 'LINEMANAGER',
                'WARDFLAG', 'CLIENT_ID', 'RCROLEID', 'PAYROLLTEMPLATE', 'HASTEEID', 'CARERNUM',
                'PAYROLLCYCLE', 'RECRUITMENTSOURCE', 'BASELOCATIONID', 'AGENCY', 'TOPFINANCESHOW'],
            'varchar(5)': ['LICENSE', 'CAR'],
            'varchar(10)': ['POSTCODE', 'WAGE', 'NOTELATEIN', 'NOTELATEOUT', 'EMAILWHENLATE',
                'EMAILSCHEDULE', 'LATETEXT'],
            'varchar(12)': ['SEX'],
            'varchar(20)': ['TITLE', 'UNIFORM', 'PPSNO'],
            'varchar(30)': ['KNOWNAS', 'PHONE', 'PHONE2', 'WORKNUMBER'],
            'varchar(32)': ['MIDDLENAME'],
            'varchar(50)': ['CARERID', 'FNAME', 'SNAME', 'COUNTY', 'EMAIL2', 'POSITION3', 'IN_OUT',
                'LATITUDE', 'LONGITUDE', 'CARERPREFIX'],
            'varchar(60)': ['COUNTRY'],
            'varchar(100)': ['USERNAME', 'ADDRESS1', 'NATIONALITY', 'TOWN', 'EMAIL', 'STATUS',
                'STATUSID', 'TAG', 'PAYROLLCOLUMN'],
            'varchar(250)': ['ADDRESS2']
        },
        'CLIENT': {
            'number(10,0)': ['ID', 'COMPANYID', 'LOCATION', 'STATE', 'SCHEDULE', 'PICID',
                'PREFERREDCONTACTMETHOD', 'AREA', 'PRIVATENOTE', 'BLACKLIST', 'PAUSEDSCHEDULE',
                'PAUSEDSTATUS', 'WARDFLAG', 'SKIPGEO', 'NFCTAG'],
            'varchar(3)': ['OCCUPTIONALT', 'PHYSIOTHERAPY', 'AIDSNONE', 'AIDSWALKINGFRAME',
                'AIDSCANE', 'AIDSZIMMER', 'AIDSCRUTCHES', 'AIDSTRIPOD', 'AIDSGRABBER',
                'AIDSWHEELCHAIR', 'DENTURESNONE', 'DENTURESLOWER', 'DENTURESUPPER',
                'DENTURESPARTIAL', 'PHNVISITS'],
            'varchar(10)': ['SEX', 'POSTCODE', 'COUNTRY', 'STATUSID'],
            'varchar(12)': ['SPEECH'],
            'varchar(20)': ['RESIDENTID', 'COUNCILID', 'TITLE', 'MARITALSTATUS', 'MEDCARDID',
                'PPSNO', 'MOBILITY', 'HEARING', 'HEARINGAID', 'SIGHT', 'GLASSES', 'NHSNUM'],
            'varchar(30)': ['CURRENTUNIT', 'NATIONALITY', 'INVOICE', 'TAG', 'CURRENTSTATUS'],
            'varchar(36)': ['UUID'],
            'varchar(40)': ['SPOUSENAME'],
            'varchar(50)': ['FNAME', 'MIDDLENAME', 'USERNAME', 'KNOWNAS', 'MOBILITYNOTES',
                'AIDSOTHER', 'LATITUDE', 'LONGITUDE'],
            'varchar(60)': ['PHONEHOME', 'PHONEMOBILE', 'CURRENTCOUNTRY', 'HSECOORDINATOR'],
            'varchar(100)': ['EMAIL'],
            'varchar(120)': ['PANICALARM'],
            'varchar(150)': ['SNAME'],
            'varchar(250)': ['CURRENTADDRESS1', 'CURRENTADDRESS2', 'ADDRESS2', 'CURRENTTOWN',
                'CURRENTCOUNTY', 'CURRENTADDRESS5', 'ALIAS'],
            'varchar(300)': ['DISLIKES', 'HEALTHINSURANCE', 'WELLFAREPAYMENTS', 'MEALSONWHEELS',
                'HOMEHELP', 'RES_PROPERTY_LIST', 'RES_WILL_TESTAMENT', 'FALLS_RISK',
                'DAILY_CONTACT_WAIVER', 'DAYCARE'],
            'varchar(500)': ['COGNITIVE_STATE'],
            'varchar(800)': ['JOBTYPES', 'MODIFIEDDIET']
        },
        'CLIENTDETAILS': {
            'number(10,0)': ['ID', 'CLIENTID', 'COMPANYID', 'LOCATIONID', 'BREAKFAST', 'DINNER',
                'TEA', 'REFERRALREASON', 'ETHNICITY', 'INVOICECYCLE', 'FUTURESTATUSCHANGESET',
                'SPLITCARER', 'TRAVELCALCULATE', 'CONTRATEDVALUE', 'RELIGION'],
            'number(19,0)': ['CLIENTNUM'],
            'varchar(1)': ['PAY_FOR_TRAVEL'],
            'varchar(30)': ['CLIENTPREFIX'],
            'varchar(50)': ['OLDADDRESS1', 'OLDTOWN'],
            'varchar(60)': ['OLDCOUNTY', 'OLDCOUNTRY'],
            'varchar(100)': ['BILLINGCODE'],
            'varchar(500)': ['REFERRALBY', 'REFERRALNOTE']
        },
        'CMASSIGNEDHOURS': {
            'number(3,0)': ['OVERNIGHT'],
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID',
                'CLIENTID', 'LENGTH', 'WEEK', 'JOBTYPE'],
            'varchar(20)': ['DAY', 'PRIORITY']
        },
        'CMCARERAVAILABILITY': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID',
                'CARERID', 'LENGTH', 'WEEK'],
            'varchar(20)': ['DAY']
        },
        'CMCARERBANK': {
            'number(10,0)': ['ID', 'CARERID', 'COMPANYID', 'LOCATIONID', 'CREATEDBY', 'DELETEDBY',
                'UPDATEDBY', 'EACCOUNT', 'SALARIED'],
            'number(10,2)': ['MONTHLYWAGE', 'YEARLYWAGE'],
            'varchar(100)': ['SORTCODE', 'ACCOUNTNUM', 'IBAN', 'BIC', 'PAYCYCLE', 'ETYPE',
                'EACCOUNTNUMBER', 'ESORTCODE', 'PROVIDEREXTRAINFO'],
            'varchar(200)': ['ACCOUNTNAME']
        },
        'CMCARERPAY': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'LOCATIONID', 'COMPANYID',
                'NO', 'MINUTES', 'OVERMINUTES', 'OVERTWORATES', 'SAME_RATE_OVERNIGHT'],
            'varchar(100)': ['CALLED', 'NAME'],
            'varchar(150)': ['EXPORTNAME'],
            'varchar(200)': ['DAY']
        },
        'CMCARERPAYPICK': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'CARERID', 'JOBTYPE',
                'COMPANYID', 'LOCATIONID', 'PAYSCALEID']
        },
        'CMCARERPAYSCALE': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'BRANCHID'],
            'varchar(100)': ['KEY'],
            'varchar(200)': ['NAME']
        },
        'CMCLIENTBILLING': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'LOCATIONID', 'COMPANYID',
                'NO', 'MINUTES', 'OVERMINUTES', 'OVERTWORATES', 'BASEDON', 'SAME_RATE_OVERNIGHT'],
            'varchar(100)': ['CALLED', 'NAME'],
            'varchar(200)': ['DAY']
        },
        'CMCLIENTBILLINGPICK': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'CLIENTID', 'JOBTYPE',
                'COMPANYID', 'LOCATIONID', 'BILLINGSCALEID']
        },
        'CMCLIENTBILLINGSCALE': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'BRANCHID'],
            'varchar(200)': ['NAME']
        },
        'CMCOMMENTS': {
            'number(10,0)': ['ID', 'CLIENTID', 'CARERID', 'COMPANYID', 'LOCATIONID', 'ADDEDBY',
                'DELETEDBY', 'EDITID'],
            'varchar(2)': ['TYPE']
        },
        'CMCOMPANYBILLINGPICK': {
            'number(10,0)': ['ID', 'JOBTYPE', 'COMPANYID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY',
                'LOCATIONID', 'BILLINGSCALEID']
        },
        'CMCONTRACTSETTINGS': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'CARERID', 'LOCATIONID',
                'COMPANYID', 'NOPAPI', 'NOHTS', 'EXCLUDETRAVELPAY'],
            'varchar(20)': ['TUPE'],
            'varchar(60)': ['CALCHOLIDAYS']
        },
        'CMCONTRACTSHOURS': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID',
                'CARERID', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN', 'WEEKHOURS',
                'ARCHIVEID']
        },
        'CMDAILYTASKS': {
            'number(10,0)': ['ID', 'CREATEDBY', 'COMPANYID', 'LOCATIONID', 'CATEGORYID', 'THEMEID'],
            'varchar(200)': ['NAME']
        },
        'CMDAILYTASKSASSIGN': {
            'number(3,0)': ['MANDATORY'],
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'KEEPRECURRING', 'COMPANYID',
                'LOCATIONID', 'CLIENTID', 'CMDAILYTASKSID', 'TASKOPTIONAL', 'STOPPEDBY', 'MON',
                'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN', 'WEEK', 'EVERYNUMDAYS', 'CAREPLANTAKENID',
                'STAGEGOALID'],
            'varchar(200)': ['TAGS', 'OUTCOMEID']
        },
        'CMDAILYTASKSASSIGNTIMES': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'CMDAILYTASKSASSIGN', 'TIMEPERIODID', 'EXTRATIME', 'WEEK', 'EVERYNUMDAYS'],
            'varchar(20)': ['DAY'],
            'varchar(200)': ['OUTCOMEID']
        },
        'CMDAILYTASKSREASON': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'CATEGORYID', 'DDORDER'],
            'varchar(200)': ['NAME']
        },
        'CMDAILYTASKSREASONCATEGORY': {
            'number(3,0)': ['COMMENTREQUIRED'],
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID',
                'ORDERBY', 'REPLACECATEGORYID'],
            'varchar(200)': ['NAME', 'COLOR']
        },
        'CMDAILYTASKSRESULTS': {
            'number(3,0)': ['MANDATORY'],
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'CLIENTID', 'COMPANYID',
                'LOCATIONID', 'TASKDONE', 'SUBTASKDONE', 'TASKASSIGNID', 'TASKID',
                'TASKSASSIGNTIMESID', 'EDITOF', 'ALERTID', 'ALERTSEENBY', 'SCRIPTLOC'],
            'varchar(500)': ['OUTCOMEID']
        },
        'CMEMPLOYEEPOSITIONS': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'ADMINFLAG', 'COMPANYID',
                'EXCLUDETAGCONFLICT', 'RESIDENTIALCAREFLAG', 'NONCAREROLE', 'ORDERBY',
                'LOCALISEDLOC'],
            'varchar(100)': ['POSITIONCODE'],
            'varchar(200)': ['NAME']
        },
        'CMETHNICITY': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID'],
            'varchar(100)': ['NAME']
        },
        'CMEXPENSES': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'CLIENTID', 'CARERID', 'TIMESHEETID', 'TIMESHEETEXPENSEID', 'EXPENSECATEGORY',
                'FILEID', 'TAXED', 'PAYCARER', 'BILLCLIENT', 'CONFIRMED', 'CONFIRMEDBY', 'JOBTYPE',
                'WALLETTRANSACTION', 'ADJUSTMENT', 'EDITID', 'STATUTORYLEAVEID', 'EXPENSEADVTYPE',
                'ISWRAP'],
            'varchar(50)': ['WRAPPARENTCODE'],
            'varchar(400)': ['DESCRIPTION']
        },
        'CMEXPENSESTYPE': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'PAYCARER', 'BILLCLIENT',
                'TAXED', 'EXPENSE', 'WALLETADJUSTMENT', 'WALLETTRANSACTION', 'COMPANYID',
                'LOCATIONID', 'PAYPERCENT', 'BILLPERCENT', 'CARERAPPVIEW'],
            'varchar(50)': ['CATEGORY', 'X3TITLE'],
            'varchar(300)': ['TYPE']
        },
        'CMFORMLISTNAME': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'LOCATIONID', 'USERSIDE',
                'SHOWSCORE', 'SHOWNA', 'LEVELID', 'LOCALIZEDLOCATION', 'AREAID'],
            'varchar(20)': ['SHOWFORM'],
            'varchar(120)': ['NAME', 'CODE', 'COMPANYID']
        },
        'CMFORMQUESTION': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'USERSIDE', 'CMFORMQUESTIONPICTUREID', 'SHOWPRINTPDF', 'LOCALIZEDLOCATION',
                'COPIED', 'AREAID'],
            'varchar(120)': ['TYPE'],
            'varchar(200)': ['FILECABLINK'],
            'varchar(250)': ['CATEGORY']
        },
        'CMFORMQUESTIONANSWERS': {
            'number(10,0)': ['ID', 'DELETEDBY', 'UPDATEDBY', 'QUESTIONID', 'VALUE', 'APPENDFORMID',
                'COMPANYID', 'LOCATIONID', 'DONE', 'ALERTANSWERLEVEL'],
            'varchar(600)': ['OUTCOME']
        },
        'CMFORMQUESTIONANSWERTABLE': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'QUESTIONID', 'COMPANYID',
                'LOCATIONID', 'DONE'],
            'varchar(200)': ['HEADER1', 'HEADER2', 'HEADER3', 'HEADER4', 'HEADER5', 'HEADER6',
                'HEADER7']
        },
        'CMFORMQUESTIONPICTURE': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'CMFORMQUESTIONID', 'COMPANYID',
                'LOCATIONID'],
            'varchar(100)': ['FILENAME', 'FILETYPE', 'FILESIZE'],
            'varchar(200)': ['NAME']
        },
        'CMFORMSANSWERS': {
            'number(10,0)': ['ID', 'UPDATEDBY', 'FORMSTAKENID', 'QUESTIONID', 'COMPANYID',
                'LOCATIONID', 'SCORE', 'ANSWEREDBY', 'ANSWEREDPAGE', 'UPDATEDHISTORY', 'FAMILYID'],
            'varchar(120)': ['TYPE']
        },
        'CMFORMSANSWERSTABLE': {
            'number(10,0)': ['ID', 'UPDATEDBY', 'FORMSTAKENID', 'QUESTIONID', 'COMPANYID',
                'LOCATIONID', 'ANSWEREDBY', 'UPDATEDHISTORYTBL', 'FAMILYID'],
            'varchar(50)': ['TYPE']
        },
        'CMFORMSPLANSTAKEN': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'COMPLETEDBY', 'CARERID', 'CLIENTID',
                'PLANID', 'COMPANYID', 'LOCATIONID', 'NEXTPLAN', 'FAMILYID', 'ARCHIVEDBY'],
            'varchar(250)': ['APPENDEDPLANNAME']
        },
        'CMFORMSSIGNOFF': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'PLANUPDATEDID', 'FORMTAKENID',
                'COMPANYID', 'LOCATIONID', 'FAMILYID', 'FUNDINGID'],
            'varchar(100)': ['PERSON', 'NAME']
        },
        'CMFORMSTAKEN': {
            'number(10,0)': ['ID', 'PLANTAKENID', 'FORMID', 'CLIENTID', 'CARERID', 'FILLEDBY',
                'COMPANYID', 'LOCATIONID', 'CLOSED', 'CLOSEDBY', 'FAMILYID'],
            'varchar(250)': ['APPENDEDFORMNAME']
        },
        'CMFORMSTRUCTURE': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'QUESTIONID',
                'QUESTIONORDER', 'COMPANYID', 'LOCATIONID', 'AREAID'],
            'varchar(120)': ['NAME']
        },
        'CMFUTURESTATUSCHANGE': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'EDITEDBY', 'UPDATEDFROMID',
                'CLIENTID', 'ORIGINALSTATE', 'ORIGINALSTATUS', 'CHANGEDSTATE', 'CHANGEDSTATUS',
                'REASONID', 'COMPLETED', 'COMPANYID', 'LOCATIONID'],
            'varchar(20)': ['CHANGETYPE']
        },
        'CMFUTURESTATUSCHANGECARER': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'EDITEDBY', 'UPDATEDFROMID', 'CARERID',
                'ORIGINALSTATE', 'ORIGINALSTATUS', 'CHANGEDSTATE', 'CHANGEDSTATUS', 'REASONID',
                'COMPLETED', 'COMPANYID', 'LOCATIONID'],
            'varchar(20)': ['CHANGETYPE']
        },
        'CMFUTURESTATUSREASON': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID'],
            'varchar(60)': ['SIDE'],
            'varchar(250)': ['REASON']
        },
        'CMHOLIDAYREQUESTS': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'CARERID', 'REQUESTSTATUS', 'ACTIONBY',
                'REJECTEDREASONID', 'COMPANYID', 'LOCATIONID', 'LEAVETYPE', 'SICKLEAVETYPE'],
            'varchar(20)': ['TYPE'],
            'varchar(500)': ['COMMENT'],
            'varchar(1000)': ['ACTIONCOMMENT']
        },
        'CMINVOICEDETAILS': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID',
                'CLIENTID', 'INVOICETEMPLATEID', 'INVOICENUM', 'INVOICEECONTACTID', 'AREAID',
                'CREATEINVOICE', 'PREVIEW', 'CREDITPARENTID', 'CREDITCHILDID', 'MANUALINVOICE',
                'BATCHID'],
            'number(10,5)': ['SPLITVALUE'],
            'number(15,5)': ['TOTALPAID', 'CURRENTBALANCE'],
            'varchar(20)': ['INVOICENUMBER', 'INVOICENUMBERPRE', 'WORKGROUPID', 'BRANCHID'],
            'varchar(50)': ['INVOICETYPE', 'SPLITTYPE', 'SAGEDEPID'],
            'varchar(100)': ['RESIDENTID', 'CODE', 'CODESPLIT', 'ORIGINCODE', 'CUSTOMERNUMBER'],
            'varchar(200)': ['JOBTYPEID', 'COMPANYLINE3', 'COMPANYLINE4', 'COMPANYLINE5',
                'COMPANYLINE6', 'INVOICEINFOLINE3', 'INVOICEINFOLINE4', 'INVOICEINFOLINE5',
                'PAYMENTDUE', 'PERIODSTART', 'PERIODFINISH', 'CLIENTNAME'],
            'varchar(250)': ['CLIENTADDRESSLINE', 'RECALCULATECHILDID'],
            'varchar(300)': ['REFERRALREASON', 'REFERRALBY'],
            'varchar(400)': ['COMPANYLINE1', 'COMPANYLINE2', 'INVOICEINFOLINE1', 'INVOICEINFOLINE2',
                'AREANAME', 'WORKGROUPNAME', 'BRANCHNAME', 'FUNDERNAME', 'MANAGERNAME',
                'COORDINATORNAME', 'COUNCILID', 'CURRENTUNIT', 'BILLINGCODE', 'NOTE',
                'RECALCULATEPARENTID'],
            'varchar(800)': ['JOBTYPENAME']
        },
        'CMINVOICEDETAILSITEMS': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'INVOICEID', 'TIMESHEETID',
                'EXPENSEID', 'COMPANYID', 'LOCATIONID', 'CLIENTID', 'CARERID', 'AREAID',
                'OVERNIGHT', 'JOBTYPEID', 'BILLINGSCALEID', 'PAYSCALEID', 'INVOICEADMINSIGNID',
                'INVOICECARERSIGN', 'PREVIEW', 'INVOICEBREAKMINUTES', 'INVOICEBREAKPAID',
                'JOBTYPEGROUPID', 'MANUALINVOICE'],
            'number(15,5)': ['BILLING', 'BILLINGDECIMALS'],
            'varchar(7)': ['BILLINGFISCALMONTH', 'EARNEDFISCALMONTH'],
            'varchar(10)': ['INVOICETRAVELMETRIC'],
            'varchar(50)': ['TYPE', 'SUBTYPE', 'NUMBERINVOICEPAGE', 'JOBTYPEGROUPCODE'],
            'varchar(100)': ['BILLINGCALLED', 'BILLINGRATE', 'PAYCALLED', 'PAYRATE',
                'INVOICESHORTDATE', 'INVOICEWEEKDATE', 'INVOICETIMEACTUAL', 'INVOICETIMESCHED',
                'INVOICECARERNAME', 'JOBTYPENAME', 'INVOICEJOBTYPENAME', 'INVOICECARERPOSITION',
                'INVOICEADMINSIGNNAME'],
            'varchar(200)': ['BILLINGSCALENAME', 'PAYSCALENAME', 'EXPENSEDESCRIPTION',
                'JOBTYPEGROUPNAME'],
            'varchar(600)': ['INVOICEPO'],
            'varchar(1000)': ['INVOICESPLITARRAY', 'INVOICESPLITARRAYPAY']
        },
        'CMINVOICEEMAIL': {
            'number(10,0)': ['ID', 'CREATEDBY', 'CLIENTID', 'COMPANYID', 'LOCATIONID', 'INVOICEID'],
            'varchar(100)': ['CODE'],
            'varchar(200)': ['CLIENTEMAIL']
        },
        'CMINVOICERECORD': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID', 'CLIENTID',
                'PAIDAMOUNT', 'NUMBEREVENTS', 'PAID', 'INVOICETYPEID', 'SIGNOFF', 'BANKDETAILS',
                'CLIENTADDRESS', 'INVOICERANBY', 'USERPRINTDATE', 'DIRECTDEBIT'],
            'varchar(20)': ['INVOICENUMBER', 'ISSUE'],
            'varchar(500)': ['JTNAME'],
            'varchar(600)': ['JOBTYPES']
        },
        'CMLEVELACCESS': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'CARERID'],
            'varchar(400)': ['ACCESSWORKGROUP'],
            'varchar(500)': ['ACCESSBRANCH']
        },
        'CMLEVELAREAWORKGROUP': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'AREAID', 'WORKGROUPID',
                'COMPANYID', 'LOCATIONID']
        },
        'CMLEVELBRANCH': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'LOCATIONID', 'COMPANYID',
                'DEFAULTTEMPLATEID', 'CAPACITY'],
            'varchar(200)': ['NAME']
        },
        'CMLEVELWORKGROUP': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'LOCATIONID', 'COMPANYID'],
            'varchar(30)': ['SAGEDEPID', 'X3SERVICETYPE'],
            'varchar(200)': ['NAME']
        },
        'CMLEVELWORKGROUPBRANCH': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'WORKGROUPID', 'BRANCHID',
                'COMPANYID', 'LOCATIONID']
        },
        'CMLOGCAREAPP': {
            'number(10,0)': ['ID', 'COMPANYID', 'LOCATIONID', 'USERID', 'USER'],
            'varchar(30)': ['PAGE']
        },
        'CMMULTIPLEQUALIFICATIONS': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'CMQUALIFICATIONSID'],
            'varchar(300)': ['FILENAME']
        },
        'CMPAINASSESSMENT': {
            'number(10,0)': ['ID', 'ADDEDBY', 'DELETEDBY', 'CLIENTID', 'PAININTENSITY', 'WORSTPAIN',
                'BESTPAIN', 'COMPANYID', 'LOCATIONID'],
            'varchar(100)': ['PAINDESCRIPTION'],
            'varchar(200)': ['PAINLOCATION', 'PAINCOLOUR'],
            'varchar(1000)': ['PROBLEM', 'CAUSE', 'TREATMENT']
        },
        'CMPLANAPPEND': {
            'number(10,0)': ['ID', 'CREATEDBY', 'PLANTAKENID', 'FORMID', 'COMPANYID', 'LOCATIONID',
                'OUTCOMEAPPEND', 'APPENDEDAFTER', 'FAMILYID']
        },
        'CMPLANS': {
            'number(10,0)': ['ID', 'DELETEDBY', 'CREATEDBY', 'UPDATEDBY', 'USERSIDE', 'COMPANYID',
                'LOCATIONID', 'SHOWPLAN', 'ADDASSIGNEDHOURS', 'ADDCONTACTS', 'ADDTAGS', 'ADMINONLY',
                'FAVOURITE', 'MANDATORYREVIEWDATE', 'MANDATORYSIGNOFF', 'CATEGORYID',
                'SHOWFAMILYAPP', 'FAMILYAPPDASHBOARD', 'LOCALIZEDLOCATION', 'AREAID'],
            'varchar(8)': ['FEATUREASMODAL'],
            'varchar(100)': ['VERSION', 'RECURRLENGTH'],
            'varchar(200)': ['NAME', 'DOCUMENTREF', 'REPLACES'],
            'varchar(250)': ['SCOPE', 'CREATEDBYNAMES', 'APPROVEDBY', 'IMPLEMENTATION', 'REVIEW'],
            'varchar(5000)': ['NOTES']
        },
        'CMPLANSTRUCTURE': {
            'number(10,0)': ['ID', 'PLANID', 'FORMID', 'FORMORDER', 'COMPANYID']
        },
        'CMPOSITIONQUALIFICATIONS': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'POSITIONID', 'QUALIFICATIONID',
                'COMPANYID', 'LOCATIONID']
        },
        'CMPRIVATENOTES': {
            'number(10,0)': ['ID', 'CLIENTID', 'CARERID', 'COMPANYID', 'LOCATIONID', 'ADDEDBY',
                'DELETEDBY']
        },
        'CMQUALIFICATIONS': {
            'number(10,0)': ['ID', 'DELETEDBY', 'MODIFIEDBY', 'CARERID', 'COMPANYID', 'LOCATIONID',
                'QUALIFICATIONID', 'FILEID', 'OUTCOMEID', 'MULTIPLE', 'ARCHIVEDBY'],
            'varchar(300)': ['FILENAME']
        },
        'CMQUALIFICATIONSARCHIVE': {
            'number(10,0)': ['ID', 'MODIFIEDBY', 'CARERID', 'COMPANYID', 'LOCATIONID',
                'QUALIFICATIONID', 'FILEID', 'SUBMITBY', 'MULTIPLE'],
            'varchar(100)': ['SUBMITTYPE'],
            'varchar(300)': ['FILENAME']
        },
        'CMQUALIFICATIONSTYPE': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'CATEGORY', 'QUALOUTCOMES', 'QUALTAGS', 'APPVIEW', 'APPUPDATE', 'APPARCHIVE'],
            'varchar(10)': ['COLOUR'],
            'varchar(30)': ['DEFAULTLENGTH', 'ALERTBEFORE'],
            'varchar(200)': ['QUALSUPERTAG'],
            'varchar(500)': ['NAME']
        },
        'CMREASONSTATUS': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'REASONID', 'STATUSID', 'COMPANYID',
                'LOCATIONID'],
            'varchar(60)': ['SIDE']
        },
        'CMSCHEDULERUNS': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'BRANCHID'],
            'varchar(10)': ['COLOR', 'RUNNUMBER'],
            'varchar(500)': ['NAME']
        },
        'CMSKINASSESSMENTS': {
            'number(10,0)': ['ID', 'HEALED', 'TYPEID', 'GRADEID', 'CLIENTID', 'PARENTID', 'COMPANYID',
                'CREATEDBY', 'DELETEDBY', 'PAINSCORE', 'UPDATEDBY', 'LOCATIONID', 'PAININTENSITYID',
                'CLASSIFICATIONID']
        },
        'CMTABCARER': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'EDITEDID', 'COMPANYID',
                'LOCATIONID', 'ACCESSOFFICEADMIN', 'ACCESSCARER', 'ACCESSCLIENT', 'ACCESSFAMILY',
                'ACCESSFILEUPLOAD'],
            'varchar(200)': ['TABNAME'],
            'varchar(1000)': ['ACCESSCARERPOSITION']
        },
        'CMTABCARERCOMMENTS': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'EDITEDID', 'CARERID',
                'COMPANYID', 'LOCATIONID', 'TABID', 'CMTABFILEUPLOADID']
        },
        'CMTABCLIENT': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'EDITEDID', 'COMPANYID',
                'LOCATIONID', 'ACCESSOFFICEADMIN', 'ACCESSCARER', 'ACCESSCLIENT', 'ACCESSFAMILY',
                'ACCESSFILEUPLOAD'],
            'varchar(200)': ['TABNAME'],
            'varchar(1000)': ['ACCESSCARERPOSITION']
        },
        'CMTABCLIENTCOMMENTS': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'EDITEDID', 'CLIENTID',
                'COMPANYID', 'LOCATIONID', 'TABID', 'CMTABFILEUPLOADID']
        },
        'CMUSERBIO': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'CLIENTID', 'CARERID', 'INVOICEEID',
                'COMPANYID', 'LOCATIONID']
        },
        'COMPANY': {
            'number(10,0)': ['ID', 'ADMINLEVEL', 'CONCURRENTCLOCKIN', 'CARERENTERTRAVEL', 'FULLDAY',
                'HOLIDAYSALLOCATEDADMIN', 'HOLIDAYWEEKCOUNT', 'HOLIDAYSDISABLESCHEDULECONFLICTS',
                'CONFLICTDISABLE', 'CROSSOVERSHOW', 'CROSSOVERSHOWNUMBER', 'RUNSSHOW',
                'CUSTOMPAGES', 'SMSAVAILABLE', 'WALLET', 'MULTIPLECLOCKIN', 'PRINTUNASSIGNED',
                'SHOWCONTRACTHOURS', 'SHOWAVAILABLE', 'SHOWREQUESTEDHOURS', 'SHOWHOLIDAYREQUEST',
                'SHOWMEDICATION', 'FCONTACTSCOMMENCEMANDATORY', 'SHOWPOSITION', 'OFFLINEMODE',
                'ADDPLANADMINABILITIES', 'NOTICEBOARD', 'PAYROLLTEMPLATE', 'FRANCHISE',
                'OTTBILLING'],
            'varchar(5)': ['GEOLOCATION'],
            'varchar(10)': ['COMPANYCODE'],
            'varchar(20)': ['UNIQUECUSTOMERNO'],
            'varchar(50)': ['NAME', 'CLIENT', 'CARER', 'ADMIN', 'EVENT', 'POSTIT', 'POST',
                'PREFERRED', 'FIRSTCONTACT', 'SERVICECOMMENCED', 'BLACKLIST', 'WARDNAME'],
            'varchar(100)': ['QUALIFICATION', 'RUNCALL', 'PPSCALL', 'BILLINGCODECALL', 'SERVERURL'],
            'varchar(150)': ['ADDRESS1', 'TOWN', 'COUNTY', 'POSTCODE', 'COUNTRY', 'PHONE', 'EMAIL'],
            'varchar(500)': ['ACCTV']
        },
        'CONTACTS': {
            'number(10,0)': ['ID', 'CLIENTID', 'CARERID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY',
                'TYPEID', 'RATING', 'COMPANYID', 'LOCATIONID', 'CONTACTSAVEDID', 'TEMPLATEID',
                'SPLITVALUEORDER', 'NHS', 'ACTIVEGP', 'PROKEYWORKER'],
            'varchar(3)': ['CONTACTNIGHT'],
            'varchar(20)': ['TYPE'],
            'varchar(50)': ['GPCODEDEFAULT', 'GPPRACTICEID', 'PROJOBCODEFHIR', 'PRONHSSPECIALCODE',
                'PROODSCODE', 'PERFHIRRELATIONCODE'],
            'varchar(60)': ['COUNTRY', 'POSTCODE'],
            'varchar(100)': ['TOWN', 'CODE', 'ORIGINCODE', 'COUNTY'],
            'varchar(150)': ['INVOICEEJOBTYPE', 'SPLITCODE'],
            'varchar(200)': ['SNAME', 'PHONE', 'PHONE2'],
            'varchar(250)': ['DETAILS'],
            'varchar(500)': ['FNAME', 'ADDRESS1', 'EMAIL', 'RELATION', 'GPPRACTICEDETAILS',
                'GPCODEDEFAULTDISPLAY', 'PROJOBROLEFHIR', 'PRONHSSPECIALTY', 'PROTEAM',
                'PROORGANISATION', 'PERRELATIONSHIPTYPE', 'PERFHIRRELATIONSHIP', 'PERCOMMENTS']
        },
        'CONTACTSSAVED': {
            'number(10,0)': ['ID', 'CLIENTSIDE', 'CARERSIDE', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY',
                'TYPEID', 'COMPANYID', 'LOCATIONID', 'TEMPLATEID', 'UPDATEJOBTYPE', 'UPDATECODES',
                'SHAREDGROUPID'],
            'varchar(30)': ['COUNTY'],
            'varchar(60)': ['COUNTRY', 'POSTCODE'],
            'varchar(100)': ['TOWN', 'CODE', 'ORIGINCODE'],
            'varchar(150)': ['INVOICEEJOBTYPE'],
            'varchar(200)': ['SNAME', 'PHONE'],
            'varchar(500)': ['FNAME', 'ADDRESS1', 'EMAIL'],
            'varchar(600)': ['RELATION']
        },
        'CONTACTTYPE': {
            'number(10,0)': ['ID', 'CARERSIDE', 'COMPANYID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY',
                'CLIENTSIDE', 'LOCATIONID']
        },
        'EVENTALERT': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID',
                'CMDAILYTASKSASSIGNID', 'MEDICATIONASSIGNID', 'ALERTID', 'CLIENTID',
                'NOTIFYCARERID']
        },
        'HOLIDAYEVENTTYPE': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'BRADFORDFACTOR', 'ACCRUALINCLUDE'],
            'varchar(100)': ['TYPECODE'],
            'varchar(500)': ['NAME']
        },
        'HOLIDAYS': {
            'number(10,0)': ['ID', 'DELETEDBY', 'UPDATEDBY', 'CARERID', 'ADDEDBY', 'COMPANYID',
                'LOCATIONID', 'EVENTTYPE', 'PAID', 'PAYRATE', 'EVENTSTOTAL', 'CONFIRMACCRUED',
                'ROLLINGENDDATE', 'REQUESTID', 'SICKLEAVETYPE'],
            'varchar(20)': ['TYPE'],
            'varchar(1000)': ['COMMENTS']
        },
        'HOLIDAYSSTARTINGBALANCE': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'CARERID', 'COMPANYID', 'LOCATIONID'],
            'varchar(1000)': ['COMMENTS']
        },
        'JOBTYPE': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID',
                'ENTITLEMENTINCLUDE', 'INCLUDENMW', 'SLEEPIN', 'EXCLUDETAGCONFLICT', 'PAYACTUAL',
                'BILLACTUAL', 'PAYMAXPLANNED', 'ARCHIVEDBY', 'SERVICETYPE', 'REPORTINGCATEGORY',
                'BANDING'],
            'varchar(20)': ['COLOR'],
            'varchar(35)': ['ACRONYM'],
            'varchar(100)': ['NAME', 'INVOICENAME', 'EXPORTNAME']
        },
        'JOBTYPEADD': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'JOBTYPEID', 'CLIENTID', 'COMPANYID',
                'LOCATIONID']
        },
        'JOBTYPEGROUPNAME': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'BUDGETCATEGORY'],
            'varchar(5)': ['ACWSFUNDINGSOURCE'],
            'varchar(50)': ['CODE'],
            'varchar(200)': ['DELETED', 'NAME']
        },
        'LOCATION': {
            'number(5,2)': ['MFPERCENT', 'VATPERCENT'],
            'number(10,0)': ['ID', 'UPDATEDBY', 'COMPANYID', 'SENDPUSH', 'NEWCARERSTATUS',
                'NEWCLIENTSTATUS', 'LATEEMAILSAFTER', 'ADMINSESSIONTIMEOUT', 'CARERSESSIONTIMEOUT',
                'UPCOMINGEVENTSTIME', 'CARING', 'WARDACCESSLINKS', 'BUFFER', 'BUFFERSHOW',
                'BREAKSHOW', 'BLOCKSHIFTSHOW', 'TIMEFREEZESHOW', 'ASSOCREQUIRED', 'NOTICEBOARDLOC',
                'LETTERS', 'HOLIDAYPAYDISABLE', 'LOGOID', 'DEFAULTTEMPLATEID', 'PAYPERCLIENT',
                'LOGOSIZEINVOICE', 'MEDICATION', 'PRNMED', 'MANDATORYMED', 'MANDATORYREQUIREDMED',
                'MEDTIMEPERIOD', 'MEDBLOCKBANKHOL', 'DIGITALTASK', 'MANDATORYTASK',
                'MANDATORYREQUIREDTASK', 'DIGITALTASKBLOCKBANKHOL', 'OUTCOMES', 'OFFICEMANAGEDPPE',
                'CARERALLOCATEDPPE', 'GROUPACCESS', 'ADDCLIENTLITE', 'CLIENTBUCKETS',
                'CLIENTBILLINGV2', 'MEDICATIONSCRIPT', 'DIGITALTASKSCRIPT', 'MEDICATIONACCESS',
                'DIGITALTASKACCESS', 'CARERIDDUPCHECK', 'CLIENTIDDUPCHECK', 'CONFLICTCHECKEDIT',
                'MAXEXPENSES', 'WALLET', 'CLOCKOUTEVENTWINDOW', 'CLOCKOUTWINDOWUPCOMING',
                'CONFLICTDISABLEAVAILABILITY', 'CONFLICTDISABLE',
                'HOLIDAYSDISABLESCHEDULECONFLICTS', 'CONFIRMLOWERLIMIT', 'CONFIRMUPPERLIMIT',
                'PREFERREDCARERSPOSTION', 'PREFERREDCARERSLENGTH', 'DELETELOCKDOWNTIMESHEETS',
                'ADMINID', 'PAYROLLTEMPLATE', 'RUNSSHOW', 'PREFIXIDS', 'RETENTIONSHOW',
                'RESIDENTIALCARE', 'EDITEVENTWINDOWFUTUREMISS', 'CLOCKOUTWINDOWMISS',
                'REQUESTEDHOURSSHOW', 'APPROVEPLANSWITCH', 'TRAVELINCLUDEHOLS',
                'RECURRINGEXPENSESSHOW', 'VATRATE', 'WALLCHARTCONFLICTDISABLE', 'FLAGSSWITCH',
                'OTTBILLING', 'BANDING_OVER_PLANNED', 'PAYMENTRECEIVED', 'NUMBERDECIMALPLACES',
                'GPCONNECTACCESS', 'CLIENTAICOMMENTS', 'HOLIDAYINCLUDEACCRUAL', 'NEWCARERAPPSHOW',
                'TIMECONFIRMCOMMENT', 'MONETARYACCRUALS', 'PAYPERIODS', 'CONTRACTIMPROVEMENTS',
                'CAREMANAGEMENTSHOW'],
            'varchar(10)': ['SKINSURFACEMEASURE'],
            'varchar(20)': ['CURRENCY', 'UNIQUECUSTOMERNO'],
            'varchar(25)': ['CONFIRMCOLORLIMIT'],
            'varchar(30)': ['PHONE', 'POSTCODE', 'EMAILCARERS', 'EMAILADMINONLY', 'EMAILSCHEDULE'],
            'varchar(60)': ['CALCHOLIDAYS', 'TIMEFREEZEOVERWRITE', 'CLIENTREQUIREDTAGS'],
            'varchar(64)': ['TIMEZONE'],
            'varchar(80)': ['NAME'],
            'varchar(100)': ['COUNTRY', 'ABN', 'ACN', 'BLOCKSHIFTCALL', 'DIGITALTASKCALL',
                'TAGCALL', 'HRPRIVATECALL', 'HRCONFIDENTIALCALL', 'REFERRALCALL', 'NAMEGOVERNANCE'],
            'varchar(130)': ['COUNTY'],
            'varchar(150)': ['EMAIL', 'ADDRESS1', 'TOWN', 'INVOICEEMAILCC'],
            'varchar(200)': ['GROUPCALL'],
            'varchar(250)': ['SCHEDULEFOOTER'],
            'varchar(1000)': ['EMAILADMINCC']
        },
        'LOGOUTREASON': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID',
                'EARLYFLAG', 'LATEFLAG', 'ORDERBY'],
            'varchar(30)': ['REASONCODE'],
            'varchar(200)': ['REASON']
        },
        'MANDATORYEVENTREASONS': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'COMPANYID'],
            'varchar(200)': ['NAME']
        },
        'MANDATORYSKIPREASON': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID',
                'CATEGORYID', 'CLIENTID', 'TIMESHEETID']
        },
        'MEDICATIONASSIGN': {
            'number(3,0)': ['MANDATORY'],
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'KEEPRECURRING', 'COMPANYID',
                'LOCATIONID', 'CLIENTID', 'MEDICATIONLISTID', 'REQUIRED', 'STOPPEDBY', 'CLONEOF',
                'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN', 'WEEK', 'EVERYNUMDAYS',
                'DUEREQUIRED'],
            'varchar(10)': ['WEEKS', 'DAYSCOUNT'],
            'varchar(100)': ['DAYS'],
            'varchar(200)': ['OUTCOMEID', 'PAINLOCATIONPERCENT', 'PAINSEVERITY']
        },
        'MEDICATIONASSIGNTIMES': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'MEDICATIONASSIGN', 'TIMEPERIODID', 'EXTRATIME'],
            'varchar(200)': ['OUTCOMEID']
        },
        'MEDICATIONBALANCE': {
            'number(10,0)': ['ID', 'CREATEDBY', 'COMPANYID', 'LOCATIONID', 'MEDICATIONID', 'WARDID',
                'WARDIN', 'WARDINFROM', 'WARDOUT', 'WARDOUTTO', 'CLIENTID', 'SECONDSIGNATURE',
                'SIGNEDBY', 'REFERENCEID', 'ARCHIVEDBY', 'RESULTID', 'DELETEDBY'],
            'varchar(20)': ['SIGNEDSTATE', 'CANCELAMOUNT'],
            'varchar(50)': ['TYPE'],
            'varchar(500)': ['DISPOSALINFO']
        },
        'MEDICATIONLIST': {
            'number(3,0)': ['PROTECTED'],
            'number(5,0)': ['MAXFREQUENCY'],
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'CLIENTID', 'NHS_MED_ID', 'EDITOF'],
            'varchar(10)': ['FREQUNIT'],
            'varchar(100)': ['MEDICATIONFORM', 'MEDICATIONROUTE'],
            'varchar(200)': ['MEDICATIONNAME', 'MEDICATIONDOSE', 'TOTALDOSE', 'NHS_MED_URL',
                'STRENGTH', 'METHOD', 'METHODUNIT']
        },
        'MEDICATIONREASON': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'CATEGORYID', 'DDORDER'],
            'varchar(200)': ['NAME']
        },
        'MEDICATIONREASONCATEGORY': {
            'number(3,0)': ['COMMENTREQUIRED'],
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID',
                'ORDER', 'REPLACECATEGORYID', 'SIGNOFFREQUIRED'],
            'varchar(3)': ['CODE'],
            'varchar(200)': ['NAME', 'COLOR']
        },
        'MEDICATIONRESULTS': {
            'number(3,0)': ['MANDATORY'],
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'CLIENTID', 'COMPANYID',
                'LOCATIONID', 'TASKDONE', 'SUBTASKDONE', 'MEDASSIGNID', 'MEDASSIGNTIMESID', 'MEDID',
                'REQUIRED', 'EDITOF', 'ALERTID', 'ALERTSEENBY', 'MEDSCRIPTLOC', 'SIGNOFF',
                'MISSEMAIL'],
            'varchar(100)': ['PAINSEVERITY'],
            'varchar(200)': ['DELETEDREASON', 'OUTCOMEID'],
            'varchar(500)': ['PAINLOCATIONPERCENT']
        },
        'MEDICATIONROUTE': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID'],
            'varchar(200)': ['NAME']
        },
        'MESSAGE': {
            'number(10,0)': ['ID', 'CREATEDBY', 'MESSAGETO', 'MESSAGEFROM', 'REQUIREDVIEW',
                'SEENBY', 'COMPANYID', 'LOCATIONID'],
            'varchar(4)': ['SEEN'],
            'varchar(10)': ['MESSAGETOTYPE', 'MESSAGEFROMTYPE']
        },
        'NOTIFICATIONS': {
            'number(10,0)': ['ID', 'COMPANYID', 'CLIENTID', 'CARERID', 'LOCATIONID', 'CATEGORYID',
                'SHOWMENU', 'USERID'],
            'varchar(300)': ['SAY']
        },
        'OUTCOME': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID',
                'ORIGINALOUTCOMEID'],
            'varchar(200)': ['NAME']
        },
        'OUTCOMECLIENTLINK': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID',
                'OUTCOMEID', 'CLIENTID', 'EVENTSASSIGNED']
        },
        'OUTCOMETASKLINK': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID',
                'OUTCOMEID', 'DAILYTASKSID', 'MEDICATIONID', 'CLIENTID']
        },
        'PERMISSIONSCARER': {
            'number(10,0)': ['ID', 'PERMISSIONID', 'CARERID', 'COMPANYID', 'LOCATIONID',
                'CREATEDBY', 'UPDATEDBY', 'DELETEDBY'],
            'varchar(20)': ['VALUE']
        },
        'PREFERREDCARERS': {
            'number(10,0)': ['ID', 'CARERID', 'CLIENTID', 'MONTHONE', 'MONTHTWO', 'POSITION', 'COMPANYID',
                'DELETEDBY', 'LOCATIONID', 'MONTHTHREE']
        },
        'RCAREAHISTORY': {
            'number(10,0)': ['ID', 'CARERID', 'CLIENTID', 'COMPANYID', 'CREATEDBY', 'UPDATEDBY',
                'LOCATIONID', 'UPDATEDAREAID', 'PREVIOUSAREAID']
        },
        'RCBED': {
            'number(10,0)': ['ID', 'RATE', 'AREAID', 'ROOMID', 'BEDTYPEID', 'COMPANYID', 'CREATEDBY',
                'DELETEDBY', 'UPDATEDBY', 'LOCATIONID', 'BLOCKEDFLAG', 'OCCUPANCYSTATUS']
        },
        'RCROLES': {
            'number(10,0)': ['ID', 'AREAID', 'WINGID', 'ORDERBY', 'ROLETYPE', 'COMPANYID', 'CREATEDBY',
                'DELETEDBY', 'UPDATEDBY', 'LOCATIONID', 'ASSOCIATEJOBTYPE']
        },
        'RCROOM': {
            'number(10,0)': ['ID', 'RATE', 'AREAID', 'BEDCAP', 'WINGID', 'ORDERBY', 'COMPANYID',
                'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'LOCATIONID']
        },
        'RCSHIFT': {
            'number(10,0)': ['ID', 'TEA', 'AREAID', 'TEAPAY', 'COMPANYID', 'CREATEDBY', 'DELETEDBY',
                'JOBTYPEID', 'OCCURANCE', 'UPDATEDBY', 'LOCATIONID']
        },
        'RCSHIFTSCHEDULE': {
            'number(10,0)': ['ID', 'TEA', 'AREAID', 'ROLEID', 'TEAPAY', 'WINGID', 'CARERID', 'GROUPID',
                'SHIFTID', 'ROLETYPE', 'ROSTERID', 'COMPANYID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY',
                'LOCATIONID', 'NONCAREFLAG', 'OUTSIDEHOME', 'TIMESHEETFLAG', 'SCHEDULEFLAGID',
                'UPSKILLREASONID']
        },
        'RCWING': {
            'number(10,0)': ['ID', 'AREAID', 'COMPANYID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY',
                'LOCATIONID']
        },
        'REASONCANCEL': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'BRANCHID', 'CLIENTBILLING', 'CARERPAY', 'DEFAULTSELECTED'],
            'varchar(200)': ['REASON', 'CANCELCODE']
        },
        'RECURR': {
            'number(10,0)': ['ID', 'CREATEDBY', 'PUBLISHEDBY', 'RECURRTYPEID', 'CLIENTID',
                'CARERID', 'JOBTYPE', 'COMPANYID', 'LOCATIONID', 'KEEPRECUR', 'NUMEVENTS',
                'HASTIMESHEETS', 'RECURRSTATEID', 'STATUSID', 'COMMENTID', 'TASKID', 'PAID',
                'PARENTID', 'OFFBANKHOLIDAYS', 'SHIFTID', 'PACKAGEID', 'RUNID', 'TEA', 'TEAPAY',
                'BLOCKSHIFT', 'TIMEFREEZE', 'FLAGID'],
            'varchar(10)': ['WEEK', 'OVERNIGHT', 'CONFIRMSCH', 'PAYRATE', 'BILLINGRATE',
                'TRAVELRATE'],
            'varchar(100)': ['DAYS', 'DAYS2']
        },
        'RECURRCANCEL': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'REASONCANCELID',
                'COMPANYID', 'LOCATIONID', 'CARERID', 'CLIENTID', 'RECURRID', 'OLDREASON',
                'TIMESHEETPAY', 'TIMESHEETBILL'],
            'varchar(1000)': ['COMMENT']
        },
        'REFERRALBY': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID'],
            'varchar(300)': ['REFERRALBYNAME']
        },
        'REFERRALREASON': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID'],
            'varchar(100)': ['NAME']
        },
        'REQUIREDACTIONS': {
            'number(10,0)': ['ID', 'COMPANYID', 'LOCATIONID', 'CREATEDBY', 'STATUSID'],
            'varchar(6)': ['SIDE'],
            'varchar(200)': ['NAME']
        },
        'REQUIREDACTIONSCOMMENT': {
            'number(10,0)': ['ID', 'CLIENTID', 'CARERID', 'CREATEDBY', 'COMPANYID', 'LOCATIONID'],
            'varchar(6)': ['SIDE'],
            'varchar(600)': ['COMMENT']
        },
        'REQUIREDACTIONSPICK': {
            'number(10,0)': ['ID', 'REQUIREDACTIONSID', 'CLIENTID', 'CARERID', 'CREATEDBY',
                'COMPANYID', 'LOCATIONID', 'POSITION'],
            'varchar(6)': ['SIDE'],
            'varchar(20)': ['DONE'],
            'varchar(500)': ['COMMENT']
        },
        'STATE': {
            'number(10,0)': ['ID'],
            'varchar(20)': ['NAME']
        },
        'STATUS': {
            'number(10,0)': ['ID', 'CREATEDBY', 'STATE', 'STATUSLEAVE', 'COMPANYID', 'LOCATIONID',
                'UPDATEDBY'],
            'varchar(30)': ['RETURNDATE'],
            'varchar(40)': ['COLOUR', 'SIDE'],
            'varchar(60)': ['TYPE'],
            'varchar(100)': ['ALERT']
        },
        'STATUSCHANGEEVENTSREMOVED': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'EDITEDBY', 'FUTURESTATUSID',
                'RECURRID', 'JOBTYPE', 'EVENTMINUTES', 'CLIENTID', 'CARERID', 'COMPANYID',
                'LOCATIONID', 'RUNID'],
            'varchar(20)': ['CHANGETYPE']
        },
        'STATUSPICK': {
            'number(10,0)': ['ID', 'CHANGEBY', 'CARERID', 'CLIENTID', 'PREVIOUSSTATUSID',
                'STATUSID', 'COMPANYID', 'LOCATIONID', 'STATUSCHANGEREASONID',
                'STATUSCLIENTTABLEID', 'STATUSCARERTABLEID']
        },
        'TAG': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID',
                'TAGCATEGORYID', 'CARERSIDE', 'CLIENTSIDE'],
            'varchar(20)': ['CLIENTCARER'],
            'varchar(100)': ['TAG', 'COLOR']
        },
        'TAGOUTCOMELINK': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'COMPANYID', 'LOCATIONID',
                'TAGID', 'OUTCOMEID']
        },
        'TAGPICK': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'CARERID', 'CLIENTID', 'TAGID',
                'COMPANYID', 'LOCATIONID', 'QUALID', 'QUALTAG', 'SUPERTAG'],
            'varchar(20)': ['STATUS']
        },
        'TASKS': {
            'number(10,0)': ['ID', 'COMPANYID', 'LOCATIONID', 'CLIENTID'],
            'varchar(100)': ['NAME']
        },
        'TIMESHEET': {
            'number(10,0)': ['ID', 'RECURRID', 'CARERID', 'CLIENTID', 'LOCATIONID', 'COMPANYID',
                'TRAVELID', 'DONTPAY', 'DONTBILL', 'CREATEDBY', 'UPDATEDBY', 'CONFIRMEDBY',
                'RESIDENTIAL', 'OVERNIGHT', 'DRIVER', 'RUNID', 'INVOICEID', 'TEA', 'TEAPAY',
                'PERCENTPAY', 'PERCENTBILL', 'CANCELLEDREASON', 'LOGREASON', 'FLAGID', 'EDITED'],
            'number(10,5)': ['TRAVELEXPENSES', 'TRAVELPAY', 'TRAVELTIMEPAY'],
            'varchar(10)': ['TIMECONFIRMED', 'STATUS'],
            'varchar(20)': ['PAYRATE', 'BILLINGRATE', 'TRAVELRATE'],
            'varchar(25)': ['LATITUDEIN', 'LONGITUDEIN', 'ACCURACYIN', 'LATITUDEOUT',
                'LONGITUDEOUT', 'ACCURACYOUT'],
            'varchar(50)': ['TIMETYPE', 'JOBTYPE', 'REFPO'],
            'varchar(100)': ['COMMENT'],
            'varchar(150)': ['COMMENTS']
        },
        'TIMESHEETDELETE': {
            'number(10,0)': ['ID', 'DELETEDBY', 'TIMESHEETID', 'RECURRID', 'CARERID', 'CLIENTID',
                'LOCATIONID', 'COMPANYID', 'TRAVELID', 'TRAVELEXPENSES', 'TRAVELPAY', 'DONTPAY',
                'DONTBILL', 'CREATEDBY', 'UPDATEDBY', 'CONFIRMEDBY', 'DRIVER', 'RUNID', 'INVOICEID'],
            'varchar(10)': ['TIMECONFIRMED', 'STATUS'],
            'varchar(20)': ['LATITUDEIN', 'LONGITUDEIN', 'ACCURACYIN', 'LATITUDEOUT',
                'LONGITUDEOUT', 'ACCURACYOUT', 'PAYRATE', 'BILLINGRATE', 'TRAVELRATE', 'PAGEDONE'],
            'varchar(50)': ['TIMETYPE', 'JOBTYPE'],
            'varchar(100)': ['COMMENT'],
            'varchar(150)': ['COMMENTS']
        },
        'TODO': {
            'number(3,0)': ['SENDMAIL'],
            'number(10,0)': ['ID', 'RATING', 'CLIENTID', 'CARERID', 'CREATEDBY', 'ADMINID',
                'COMPANYID', 'LOCATIONID', 'MEDICATIONASSIGNID', 'MEDICATIONASSIGNTIMESID',
                'MEDICATIONRESULTSID', 'AREAID'],
            'varchar(3)': ['PROGRESS'],
            'varchar(10)': ['PRIORITY', 'ISSUE', 'STATUS', 'SEEN', 'ISSUEPREFIX'],
            'varchar(20)': ['TODOSEQ'],
            'varchar(50)': ['TODONUMBER'],
            'varchar(100)': ['ISSUEFROMPHONE', 'FILESIZE', 'FILETYPE'],
            'varchar(200)': ['ISSUEFROM'],
            'varchar(500)': ['NOTIFIED', 'FILENAME']
        },
        'TODO_ISSUE': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'PREFIXNUMBER', 'MANDATORYCARER', 'MANDATORYCLIENT', 'DAYSNOTIFY'],
            'varchar(5)': ['PREFIX'],
            'varchar(50)': ['NAME'],
            'varchar(200)': ['CARERNOTIFY']
        },
        'TODO_ISSUE_SUBTASK': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'ISSUEID', 'ORDERBYTASK', 'SHOWTASK', 'DAYS'],
            'varchar(250)': ['DESCRIPTION']
        },
        'TODO_ISSUE_SUBTASK_ITEMS': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'TODOID', 'ORDERBYTASK', 'SUBTASKID', 'ASSIGNID', 'STATUS']
        },
        'TODO_ISSUE_SUBTASK_STATUS': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'SEQUENCE', 'CLOSED', 'NEW'],
            'varchar(50)': ['STATUS']
        },
        'TODO_UPLOAD': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDBY', 'DELETEDBY', 'COMPANYID', 'LOCATIONID',
                'TYPEID'],
            'varchar(100)': ['TYPELOCATION', 'FILESIZE', 'FILETYPE', 'URL'],
            'varchar(500)': ['FILENAME']
        },
        'TRAININGSESSION': {
            'number(10,0)': ['ID', 'TRAININGSESSIONID', 'COMPANYID', 'LOCATIONID', 'DURATION'],
            'varchar(100)': ['SIGNEDOFBY', 'SESSIONBY']
        },
        'TRAVELDISTANCE': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'STARTCLIENT',
                'FINISHCLIENT', 'COMPANYID', 'LOCATIONID', 'MANUAL', 'TRANSPORTCATEGORY'],
            'varchar(30)': ['STARTLATITUDE', 'STARTLONGITUDE', 'FINISHLATITUDE', 'FINISHLONGITUDE']
        },
        'TRAVELDISTANCECARERCLIENT': {
            'number(10,0)': ['ID', 'CREATEDBY', 'DELETEDBY', 'UPDATEDBY', 'CARERID', 'CLIENTID',
                'COMPANYID', 'LOCATIONID', 'MANUAL', 'TRANSPORTCATEGORY'],
            'varchar(25)': ['CARERLATITUDE', 'CARERLONGITUDE', 'CLIENTLATITUDE', 'CLIENTLONGITUDE']
        },
        'UPDATEDFIELD': {
            'number(10,0)': ['ID', 'CREATEDBY', 'UPDATEDFIELDTYPEID', 'UPDATEDID', 'CLIENTID',
                'CARERID', 'COMPANYID', 'LOCATIONID']
        },
        'VIEW_EVENTS': {
            'number(10,0)': ['ID', 'COMPANYID', 'LOCATIONID', 'RECURRID', 'CLIENTID', 'CARERID',
                'JOBTYPE', 'OVERNIGHT'],
            'varchar(50)': ['STATUS']
        },
        'VIEW_FINANCE': {
            'number(10,0)': ['ID', 'COMPANYID', 'LOCATIONID', 'EVENTID', 'TIMESHEETRECURRID',
                'CLIENT_ID', 'CARER_ID', 'AREA_ID', 'JOBTYPEID', 'DONTBILL', 'DONTPAY',
                'BILLINGSCALEID', 'PAYSCALEID', 'OVERNIGHT', 'JOBTYPEGROUPID', 'RUNID'],
            'number(10,2)': ['BILLING', 'PAY', 'BILLINGRATE', 'PAYRATE', 'TRAVELPAY', 'TRAVELRATE'],
            'varchar(7)': ['BILLINGFISCALMONTH', 'EARNEDFISCALMONTH'],
            'varchar(50)': ['SHIFT_STATUS', 'JOBTYPEGROUPCODE'],
            'varchar(100)': ['BRANCH_ID', 'WORKGROUP_ID', 'CLIENTPOSTALCODE'],
            'varchar(200)': ['COORDINATOR', 'BILLINGCODE', 'REFERRALREASON', 'UNITID', 'COUNCILID',
                'CAREMANAGER', 'FUNDER', 'BILLINGSCALENAME', 'PAYSCALENAME', 'SERVICETYPE',
                'JOBTYPEGROUPNAME'],
            'varchar(250)': ['AREA_NAME'],
            'varchar(500)': ['CLIENT_NAME', 'CARER_NAME', 'BRANCH', 'WORKGROUP', 'CANCELLED_REASON',
                'JOBTYPENAME', 'RUNNAME'],
            'varchar(1000)': ['INVOICESPLITARRAY', 'INVOICESPLITARRAYPAY']
        }
    }) }}
{% endmacro %}
