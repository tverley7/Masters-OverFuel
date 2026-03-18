USE [WinNetStarApp]
GO
/****** Object:  StoredProcedure [dbo].[GetWholegoodCSVExtract_OverFuel]    Script Date: 3/18/2026 8:05:44 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
--DECLARE
ALTER PROCEDURE [dbo].[GetWholegoodCSVExtract_OverFuel]
  @InterfaceName    VARCHAR(50)    = 'OverFuelUpload',
  @Company_ID       INT            = 0,        -- 0 = all companies
  @Location_ID      INT            = 0,        -- 0 = all locations (within company scope)
  @LocationList     NVARCHAR(MAX)  = NULL,     -- e.g. N'2,5' explicit list (intersected with @Company_ID when > 0)
  @OPT_ZIP          BIT            = 0,        -- 1 = zip final CSV
  @OPT_FTP          BIT            = 0,        -- 1 = SFTP via psftp
  @OPT_EMAIL        BIT            = 0         -- 1 = send via dbmail
AS
BEGIN
  SET NOCOUNT ON;

  IF OBJECT_ID('dbo.WholegoodCSVExtractData_OverFuel','U') IS NULL
  BEGIN
    RAISERROR('Staging table dbo.WholegoodCSVExtractData_OverFuel does not exist.', 16, 1);
    RETURN;
  END

  -----------------------------------------------------------------------
  -- 0) Vars & scratch
  -----------------------------------------------------------------------
  DECLARE
    @Cmd2Exec           NVARCHAR(4000),
    @UserPass           VARCHAR(255),
    @OutboundPath       VARCHAR(255) = 'C:\Pricefiles_Masters\CSV\outgoing',
    @FullName           VARCHAR(255) = 'Masters_AFS_Wholegoods.csv', -- << fixed filename
    @ZIP_Extension      VARCHAR(10)  = '',
    @FTP_Server         VARCHAR(255),
    @FTP_UserID         VARCHAR(255),
    @FTP_Password       VARCHAR(255),
    @FTP_RemotePath     VARCHAR(255),
    @FTP_LocalPath      VARCHAR(255),
    @ServerName         SYSNAME      = @@SERVERNAME,
    @BCPAuth            VARCHAR(400),
    @RowsInserted       INT          = 0,
    @DidBCP             BIT          = 0,
    @DidZIP             BIT          = 0,
    @DidFTP             BIT          = 0,
    @DidEmail           BIT          = 0,
    @FinalFile          VARCHAR(1024)= '',
    @ScopeCount         INT          = 0,
    @LocationListPrint  NVARCHAR(MAX),
    @LoadedLocCount     INT          = 0,
    @LoadedRows         INT          = 0;

  SET @LocationListPrint = CASE WHEN NULLIF(LTRIM(RTRIM(@LocationList)),N'') IS NULL THEN N'(null)' ELSE @LocationList END;

  IF OBJECT_ID('tempdb..#CmdOut') IS NOT NULL DROP TABLE #CmdOut;
  CREATE TABLE #CmdOut ([line] NVARCHAR(4000));

  IF OBJECT_ID('tempdb..#ScopeLocations') IS NOT NULL DROP TABLE #ScopeLocations;
  CREATE TABLE #ScopeLocations (
    Location_ID    INT           NOT NULL PRIMARY KEY,
    Company_ID     INT           NOT NULL,
    Location_Name  NVARCHAR(200) NULL
  );

  -----------------------------------------------------------------------
  -- 1) Build scope
  -----------------------------------------------------------------------
  IF NULLIF(LTRIM(RTRIM(@LocationList)),N'') IS NOT NULL
  BEGIN
    IF OBJECT_ID('tempdb..#List') IS NOT NULL DROP TABLE #List;
    CREATE TABLE #List (Location_ID INT PRIMARY KEY);
    INSERT #List(Location_ID)
    SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS INT)
    FROM STRING_SPLIT(@LocationList, N',')
    WHERE NULLIF(LTRIM(RTRIM(value)), N'') IS NOT NULL;

    INSERT #ScopeLocations (Location_ID, Company_ID, Location_Name)
    SELECT ecl.Location_ID, ecl.Company_ID, ecl.Location_Name
    FROM dbo.EnterpriseCompanyLocationList ecl
    INNER JOIN #List L ON L.Location_ID = ecl.Location_ID
    WHERE (@Company_ID = 0 OR ecl.Company_ID = @Company_ID);
  END
  ELSE
  BEGIN
    IF (@Company_ID = 0 AND @Location_ID = 0)
      INSERT #ScopeLocations SELECT Location_ID, Company_ID, Location_Name FROM dbo.EnterpriseCompanyLocationList;
    ELSE IF (@Company_ID > 0 AND @Location_ID = 0)
      INSERT #ScopeLocations SELECT Location_ID, Company_ID, Location_Name FROM dbo.EnterpriseCompanyLocationList WHERE Company_ID = @Company_ID;
    ELSE IF (@Company_ID > 0 AND @Location_ID > 0)
      INSERT #ScopeLocations SELECT Location_ID, Company_ID, Location_Name FROM dbo.EnterpriseCompanyLocationList WHERE Company_ID = @Company_ID AND Location_ID = @Location_ID;
    ELSE IF (@Company_ID = 0 AND @Location_ID > 0)
      INSERT #ScopeLocations SELECT Location_ID, Company_ID, Location_Name FROM dbo.EnterpriseCompanyLocationList WHERE Location_ID = @Location_ID;
  END

  SELECT @ScopeCount = COUNT(*) FROM #ScopeLocations;
  IF @ScopeCount = 0
  BEGIN
    RAISERROR('No locations matched the requested scope (Company_ID=%d, Location_ID=%d, LocationList=%s).', 16, 1, @Company_ID, @Location_ID, @LocationListPrint);
    RETURN;
  END

  RAISERROR('Starting OverFuel extract. Company_ID=%d, Location_ID=%d, LocationList=%s. Locations selected: %d.',
            0, 1, @Company_ID, @Location_ID, @LocationListPrint, @ScopeCount) WITH NOWAIT;

  -----------------------------------------------------------------------
  -- 2) Resolve outbound path & FTP context
  -----------------------------------------------------------------------
  DECLARE @FTPLocation_ID INT = CASE WHEN @ScopeCount = 1 THEN (SELECT TOP 1 Location_ID FROM #ScopeLocations) ELSE 0 END;

  SELECT
    @FTP_Server     = [Server],
    @FTP_UserID     = [UserID],
    @FTP_Password   = [Password],
    @FTP_RemotePath = [RemotePath],
    @FTP_LocalPath  = [LocalPath]
  FROM dbo.FTPService
  WHERE Service = @InterfaceName AND LocationID = @FTPLocation_ID;

  IF @@ROWCOUNT = 0
  BEGIN
    SELECT
      @FTP_Server     = [Server],
      @FTP_UserID     = [UserID],
      @FTP_Password   = [Password],
      @FTP_RemotePath = [RemotePath],
      @FTP_LocalPath  = [LocalPath]
    FROM dbo.FTPService
    WHERE Service = @InterfaceName AND LocationID = 0;
  END

  IF ISNULL(@FTP_LocalPath,'') <> '' SET @OutboundPath = @FTP_LocalPath;

  SET @Cmd2Exec = N'IF NOT EXIST "' + @OutboundPath + N'" MKDIR "' + @OutboundPath + N'"';
  EXEC master..xp_cmdshell @Cmd2Exec, NO_OUTPUT;

  -----------------------------------------------------------------------
  -- 3) Fresh staging (wipe every run)
  -----------------------------------------------------------------------
  BEGIN TRY
    TRUNCATE TABLE dbo.WholegoodCSVExtractData_OverFuel;
  END TRY
  BEGIN CATCH
    DELETE FROM dbo.WholegoodCSVExtractData_OverFuel;
  END CATCH

  -----------------------------------------------------------------------
  -- 4) Load staging (SalesStatus = 2; location-owning; simple OnSalesOrder)
  -----------------------------------------------------------------------
  ;WITH UDFMap AS (
      SELECT
          v.Party_ID,

          -- core UDFs (by UDF_ID)
          MAX(CASE WHEN v.UDF_ID = 62  THEN CAST(v.FieldValue AS nvarchar(max)) END) AS BodyMake,
          MAX(CASE WHEN v.UDF_ID = 63  THEN CAST(v.FieldValue AS nvarchar(max)) END) AS BodyModel,
          MAX(CASE WHEN v.UDF_ID = 64  THEN CAST(v.FieldValue AS nvarchar(max)) END) AS SeatCap,
          MAX(CASE WHEN v.UDF_ID = 65  THEN CAST(v.FieldValue AS nvarchar(max)) END) AS WheelCap,
          MAX(CASE WHEN v.UDF_ID = 81  THEN CAST(v.FieldValue AS nvarchar(max)) END) AS BrakeType,
          MAX(CASE WHEN v.UDF_ID = 82  THEN CAST(v.FieldValue AS nvarchar(max)) END) AS FuelType,
          MAX(CASE WHEN v.UDF_ID = 69  THEN CAST(v.FieldValue AS nvarchar(max)) END) AS ExteriorColor,
          MAX(CASE WHEN v.UDF_ID = 70  THEN CAST(v.FieldValue AS nvarchar(max)) END) AS InteriorColor,
          MAX(CASE WHEN v.UDF_ID = 117 THEN CAST(v.FieldValue AS nvarchar(max)) END) AS UpholsteryType,
          MAX(CASE WHEN v.UDF_ID = 66  THEN CAST(v.FieldValue AS nvarchar(max)) END) AS Luggage,
          MAX(CASE WHEN v.UDF_ID = 167 THEN CAST(v.FieldValue AS nvarchar(max)) END) AS CDLRequired,

          -- additional mapped UDFs by UDF_ID (per your tables)
          MAX(CASE WHEN v.UDF_ID = 86  THEN CAST(v.FieldValue AS nvarchar(max)) END) AS EntrancePowerDoor,
          MAX(CASE WHEN v.UDF_ID = 95  THEN CAST(v.FieldValue AS nvarchar(max)) END) AS RearDoor,
          MAX(CASE WHEN v.UDF_ID = 93  THEN CAST(v.FieldValue AS nvarchar(max)) END) AS EntryDoorSwitch,
          MAX(CASE WHEN v.UDF_ID = 73  THEN CAST(v.FieldValue AS nvarchar(max)) END) AS Stereo,
          MAX(CASE WHEN v.UDF_ID = 114 THEN CAST(v.FieldValue AS nvarchar(max)) END) AS USB,
          MAX(CASE WHEN v.UDF_ID = 104 THEN CAST(v.FieldValue AS nvarchar(max)) END) AS FloorColor,
          MAX(CASE WHEN v.UDF_ID = 74  THEN CAST(v.FieldValue AS nvarchar(max)) END) AS FlooringType,
          MAX(CASE WHEN v.UDF_ID = 77  THEN CAST(v.FieldValue AS nvarchar(max)) END) AS AC,
          MAX(CASE WHEN v.UDF_ID = 103 THEN CAST(v.FieldValue AS nvarchar(max)) END) AS CondenserLocation,
          MAX(CASE WHEN v.UDF_ID = 75  THEN CAST(v.FieldValue AS nvarchar(max)) END) AS MirrorType,
          MAX(CASE WHEN v.UDF_ID = 143  THEN CAST(v.FieldValue AS nvarchar(max)) END) AS BackupCamera,
          MAX(CASE WHEN v.UDF_ID = 144  THEN CAST(v.FieldValue AS nvarchar(max)) END) AS FirstAidEtc,
          MAX(CASE WHEN v.UDF_ID = 174 THEN CAST(v.FieldValue AS nvarchar(max)) END) AS InteriorMaterial,
          MAX(CASE WHEN v.UDF_ID = 115 THEN CAST(v.FieldValue AS nvarchar(max)) END) AS SeatHeight,
          MAX(CASE WHEN v.UDF_ID = 116 THEN CAST(v.FieldValue AS nvarchar(max)) END) AS UpholsteryPrimaryColor,
          MAX(CASE WHEN v.UDF_ID = 209 THEN CAST(v.FieldValue AS nvarchar(max)) END) AS UnitStatus,
          MAX(CASE WHEN v.UDF_ID = 121 THEN CAST(v.FieldValue AS nvarchar(max)) END) AS [SellReady(Service)],
          MAX(CASE WHEN v.UDF_ID = 80  THEN CAST(v.FieldValue AS nvarchar(max)) END) AS ChassisStatus,
          -- Manager Special (UDF_ID 124)
          MAX(CASE WHEN v.UDF_ID = 124 THEN CAST(v.FieldValue AS nvarchar(max)) END) AS ManagerSpecial
      FROM dbo.UserDefinedFieldValue v
      GROUP BY v.Party_ID
  ),
  OnSO AS (
      SELECT wgSO.Wholegood_ID
      FROM dbo.Wholegood wgSO
      WHERE wgSO.SalesStatus = 4
        AND wgSO.WholegoodType = 'Sales'
  )
  INSERT dbo.WholegoodCSVExtractData_OverFuel
  (
    DealerID, Wholegood_ID, LocationName,
    Location_ID, VIN,
    StockNumber, Category, ShortDescription, [Description], ImageURL,
    ModelYear, Make, Model, BodyMake, BodyModel, [Condition], Location, WheelchairAccessible,
    SeatedCapacity, WheelchairCapacity, Miles, BrakeType, FuelType, Engine, Transmission,
    ExteriorColor, InteriorColor, UpholsteryType, Luggage, CDLRequired,
    Age, ArrivalDate,
    EntrancePowerDoor, RearDoor, EntryDoorSwitch, Stereo, USB, FloorColor, FlooringType, AC,
    CondenserLocation, MirrorType, BackupCamera, FirstAidEtc, InteriorMaterial, SeatHeight,
    UpholsteryPrimaryColor, UnitStatus, [SellReady(Service)], ChassisStatus, AskingPrice,
    ManagerSpecial,
    OnSalesOrder
  )
  SELECT
   'mastertrans' AS DealerID,
    wg.Wholegood_ID,
    ecl.Location_Name,
    wg.CurrentOwnerLocation_ID                                        AS Location_ID,
    NULLIF(LTRIM(RTRIM(wg.SerialNumber)),'')                          AS VIN,

    COALESCE(wg.StockNumber,'')                                       AS StockNumber,
    COALESCE(refCategory.Description,'')                               AS Category,

    -- ShortDescription
    COALESCE(CONCAT(
        'This ', COALESCE(wg.NewUsed,''), ' ',
        COALESCE(u.BodyMake,''), ' ',
        COALESCE(u.BodyModel,''),
        ' is for sale at Master''s Transportation.'
    ), '') AS ShortDescription,

    -- Description (succinct)
    COALESCE(CONCAT(
        'This ', COALESCE(wg.NewUsed,''), ' ',
        COALESCE(u.BodyMake,''), ' ', COALESCE(u.BodyModel,''),
        ' is built on the ', COALESCE(refMake.Description,''), ' ', COALESCE(refModel.Description,''),
        ' chassis with seating for ', COALESCE(u.SeatCap,''),
        '. Powered by ', COALESCE(wg.Engine,''), ' ', COALESCE(u.FuelType,''),
        ' and ', COALESCE(wg.Transmission,''), ' transmission.'
    ), '') AS [Description],

    ''                                                               AS ImageURL,
    COALESCE(CAST(wg.Year AS VARCHAR(4)),'')                         AS ModelYear,
    COALESCE(refMake.Description,'')                                 AS Make,
    COALESCE(refModel.Description,'')                                AS Model,
    COALESCE(u.BodyMake,'')                                          AS BodyMake,
    COALESCE(u.BodyModel,'')                                         AS BodyModel,
    COALESCE(wg.NewUsed,'')                                          AS [Condition],
    COALESCE(wg.PhysicalLocation,'')                                 AS Location,
    COALESCE(CASE WHEN TRY_CAST(u.WheelCap AS INT) > 0 THEN 'Yes' ELSE 'No' END,'')
                                                                     AS WheelchairAccessible,
    COALESCE(u.SeatCap,'')                                           AS SeatedCapacity,
    COALESCE(u.WheelCap,'')                                          AS WheelchairCapacity,
    COALESCE(CAST(wg.Miles AS VARCHAR(50)),'')                       AS Miles,
    COALESCE(u.BrakeType,'')                                         AS BrakeType,
    COALESCE(u.FuelType,'')                                          AS FuelType,
    COALESCE(wg.Engine,'')                                           AS Engine,
    COALESCE(wg.Transmission,'')                                     AS Transmission,
    COALESCE(u.ExteriorColor,'')                                     AS ExteriorColor,
    COALESCE(u.InteriorColor,'')                                     AS InteriorColor,
    COALESCE(u.UpholsteryType,'')                                    AS UpholsteryType,
    COALESCE(u.Luggage,'')                                           AS Luggage,
    COALESCE(u.CDLRequired,'')                                       AS CDLRequired,

    CASE WHEN wg.ArrivalDate IS NULL OR wg.ArrivalDate > GETDATE() THEN 0
         ELSE DATEDIFF(DAY, wg.ArrivalDate, GETDATE())
    END AS Age,

    CASE WHEN wg.ArrivalDate IS NULL THEN ''
         ELSE CONVERT(CHAR(10), wg.ArrivalDate, 23)  -- yyyy-MM-dd
    END AS ArrivalDate,

    -- mapped UDF columns
    COALESCE(u.EntrancePowerDoor,'')                                 AS EntrancePowerDoor,
    COALESCE(u.RearDoor,'')                                          AS RearDoor,
    COALESCE(u.EntryDoorSwitch,'')                                   AS EntryDoorSwitch,
    COALESCE(u.Stereo,'')                                            AS Stereo,
    COALESCE(u.USB,'')                                               AS USB,
    COALESCE(u.FloorColor,'')                                        AS FloorColor,
    COALESCE(u.FlooringType,'')                                      AS FlooringType,
    COALESCE(u.AC,'')                                                AS AC,
    COALESCE(u.CondenserLocation,'')                                 AS CondenserLocation,
    COALESCE(u.MirrorType,'')                                        AS MirrorType,
    COALESCE(u.BackupCamera,'')                                      AS BackupCamera,
    COALESCE(u.FirstAidEtc,'')                                       AS FirstAidEtc,
    COALESCE(u.InteriorMaterial,'')                                  AS InteriorMaterial,
    COALESCE(u.SeatHeight,'')                                        AS SeatHeight,
    COALESCE(u.UpholsteryPrimaryColor,'')                            AS UpholsteryPrimaryColor,
    COALESCE(u.UnitStatus,'')                                        AS UnitStatus,
    COALESCE(u.[SellReady(Service)],'')                              AS [SellReady(Service)],
    COALESCE(u.ChassisStatus,'')                                     AS ChassisStatus,
    wg.AskingPrice                                                   AS AskingPrice,
    COALESCE(u.ManagerSpecial,'')                                    AS ManagerSpecial,

    CASE WHEN EXISTS (SELECT 1 FROM OnSO s WHERE s.Wholegood_ID = wg.Wholegood_ID)
         THEN 'Yes' ELSE 'No' END                                    AS OnSalesOrder

  FROM dbo.Wholegood wg
  INNER JOIN #ScopeLocations L ON L.Location_ID = wg.CurrentOwnerLocation_ID
  INNER JOIN dbo.EnterpriseCompanyLocationList ecl ON ecl.Location_ID = wg.CurrentOwnerLocation_ID
  LEFT  JOIN dbo.GenericLookup         refCategory ON wg.CategoryID = refCategory.Database_ID
  LEFT  JOIN dbo.GenericLookup         refMake     ON wg.MakeID     = refMake.Database_ID
  LEFT  JOIN dbo.WGModel               refModel    ON wg.ModelID    = refModel.Database_ID
  LEFT  JOIN UDFMap u ON u.Party_ID = wg.Wholegood_ID
  WHERE wg.SalesStatus IN (2,4)
  AND (CurrentOwnerCustomer_ID <> 2532 OR CurrentOwnerCustomer_ID IS NULL)
  AND (CurrentOwnerCustomer_ID <> 2678 OR CurrentOwnerCustomer_ID IS NULL)
  AND wg.Inactive = 0;


  SET @RowsInserted = @@ROWCOUNT;
  SELECT @LoadedLocCount = COUNT(*) FROM (SELECT DISTINCT Location_ID FROM dbo.WholegoodCSVExtractData_OverFuel) d;
  SET @LoadedRows = @RowsInserted;

  -- Clean/quote text to protect CSV
  UPDATE dbo.WholegoodCSVExtractData_OverFuel
     SET ShortDescription = REPLACE(REPLACE(ShortDescription, CHAR(13), ' '), CHAR(10), ' '),
         [Description]    = REPLACE(REPLACE([Description],    CHAR(13), ' '), CHAR(10), ' ');
 /* UPDATE dbo.WholegoodCSVExtractData_OverFuel
     SET ShortDescription = '"' + REPLACE(ShortDescription, '"', '""') + '"',
         [Description]    = '"' + REPLACE([Description],    '"', '""') + '"';
		 */

  RAISERROR('Loaded %d rows into staging across %d location(s).', 0, 1, @LoadedRows, @LoadedLocCount) WITH NOWAIT;

-----------------------------------------------------------------------
-- 5) CSV via BCP — safe CSV with header, short bcp commands
-----------------------------------------------------------------------
DECLARE @HeaderLiteral NVARCHAR(MAX),
        @BodySelect    NVARCHAR(MAX),
        @CsvQuery      NVARCHAR(MAX),
        @ViewSQL       NVARCHAR(MAX),
        @TmpBody       NVARCHAR(1024);

-- 5a) Create or alter a view that returns all columns already CSV-quoted:
--     per column: " + REPLACE(value, """", """""") + "
SELECT @ViewSQL = N'CREATE OR ALTER VIEW dbo.vw_WholegoodCSV_OverFuel_Quoted AS
SELECT ' + STUFF((
    SELECT N',' +
           N'CHAR(34) + REPLACE(COALESCE(CAST(' + QUOTENAME(c.name) +
           N' AS nvarchar(max)), N''''), N''"'' , N''""'') + CHAR(34) AS ' + QUOTENAME(c.name)
    FROM sys.columns c
    WHERE c.object_id = OBJECT_ID('dbo.WholegoodCSVExtractData_OverFuel')
    ORDER BY c.column_id
    FOR XML PATH(''), TYPE
).value('.','nvarchar(max)'), 1, 1, N'')
+ N' FROM dbo.WholegoodCSVExtractData_OverFuel;';
EXEC (@ViewSQL);

-- 5b) Build a quoted header row: SELECT '"Col1"','"Col2"',...
SELECT @HeaderLiteral =
    N'SELECT ' + STUFF((
        SELECT N',''' + QUOTENAME(c.name, '"') + N''''
        FROM sys.columns c
        WHERE c.object_id = OBJECT_ID('dbo.WholegoodCSVExtractData_OverFuel')
        ORDER BY c.column_id
        FOR XML PATH(''), TYPE
    ).value('.','nvarchar(max)'), 1, 1, N'');

-- temp body file path
SET @TmpBody = @OutboundPath + N'\_body.tmp';

-----------------------------------------------------------------------
-- 5c) Write header directly to FINAL file (simple ECHO method)
-----------------------------------------------------------------------
-- Build header line: "col1","col2",...
DECLARE @HeaderLine NVARCHAR(MAX);

SELECT @HeaderLine =
    STRING_AGG('"' + c.name + '"', ',')
    FROM sys.columns c
    WHERE c.object_id = OBJECT_ID('dbo.WholegoodCSVExtractData_OverFuel');

-- Defensive: remove special characters for cmd.exe
SET @HeaderLine = REPLACE(REPLACE(REPLACE(@HeaderLine, '&', '^&'), '|', '^|'), '>', '^>');

-- Build ECHO command to create the file with header
SET @Cmd2Exec =
    N'cmd /c ECHO ' + @HeaderLine + N'> "' + @OutboundPath + N'\' + @FullName + N'"';

PRINT @Cmd2Exec;  -- optional: see what runs
EXEC master..xp_cmdshell @Cmd2Exec, NO_OUTPUT;

-- Verify file was created
TRUNCATE TABLE #CmdOut;
SET @Cmd2Exec =
    N'cmd /c IF EXIST "' + @OutboundPath + N'\' + @FullName + N'" (ECHO HDR_OK) ELSE (ECHO HDR_FAIL)';
INSERT #CmdOut EXEC master..xp_cmdshell @Cmd2Exec;

IF NOT EXISTS (SELECT 1 FROM #CmdOut WHERE [line] LIKE '%HDR_OK%')
BEGIN
    RAISERROR('Header write failed (ECHO). Check path or permissions.',16,1);
    RETURN;
END


-----------------------------------------------------------------------
-- 5d) Export body (final working version)
-----------------------------------------------------------------------

-- 1) Ensure no leftover temp file before export
SET @Cmd2Exec =
    N'cmd /c IF EXIST "' + REPLACE(@OutboundPath + '\_body.tmp', '\\', '\') +
    N'" DEL /Q "' + REPLACE(@OutboundPath + '\_body.tmp', '\\', '\') + N'"';
EXEC master..xp_cmdshell @Cmd2Exec, NO_OUTPUT;

-- 2) Build full BCP command exactly as verified working in xp_cmdshell
SET @Cmd2Exec = N'cmd /c ""C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\bcp.exe" ' +
    N'"SELECT * FROM WinNetStarApp.dbo.vw_WholegoodCSV_OverFuel_Quoted" queryout "' +
    REPLACE(@OutboundPath + '\_body.tmp', '\\', '\') +
    N'" -S "127.0.0.1\MASTERS,61501" -d "WinNetStarApp" -T -c -C 65001 -t"," -r \n"';


-- 3) Debug output — print full executed command for verification
PRINT 'DEBUG START >>>';
PRINT @Cmd2Exec;
PRINT '<<< DEBUG END';

-- 4) Execute BCP command
TRUNCATE TABLE #CmdOut;
INSERT #CmdOut EXEC master..xp_cmdshell @Cmd2Exec;

-- Show BCP output lines for visibility (remove later if not needed)
SELECT [line] FROM #CmdOut;

-- 5) Verify file creation — dump directory contents and confirm file
TRUNCATE TABLE #CmdOut;
SET @Cmd2Exec = N'dir "' + REPLACE(@OutboundPath, '\\', '\') + N'"';
INSERT #CmdOut EXEC master..xp_cmdshell @Cmd2Exec;

SELECT [line] FROM #CmdOut; -- debug: list all files in directory

IF NOT EXISTS (SELECT 1 FROM #CmdOut WHERE [line] LIKE '%_body.tmp%')
BEGIN
    RAISERROR('BCP failed writing body. File not created.', 16, 1);
    RETURN;
END

-- 6) Success confirmation
RAISERROR('BCP body export completed successfully.', 0, 1) WITH NOWAIT;




-----------------------------------------------------------------------
-- 5e) Append body to final and clean up
-----------------------------------------------------------------------
SET @Cmd2Exec =
    N'cmd /c type "' + @OutboundPath + N'\_body.tmp" >> "' + @OutboundPath + N'\' + @FullName + N'"';
EXEC master..xp_cmdshell @Cmd2Exec, NO_OUTPUT;

SET @Cmd2Exec =
    N'del /q "' + @OutboundPath + N'\_body.tmp"';
EXEC master..xp_cmdshell @Cmd2Exec, NO_OUTPUT;

-- Mark success
SET @DidBCP = 1;




  -----------------------------------------------------------------------
  -- 6) ZIP (optional)
  -----------------------------------------------------------------------
  IF @OPT_ZIP = 1
  BEGIN
    SET @ZIP_Extension = '.zip';

    SET @Cmd2Exec = N'IF EXIST "' + @OutboundPath + N'\' + @FullName + @ZIP_Extension +
                    N'" DEL /Q "' + @OutboundPath + N'\' + @FullName + @ZIP_Extension + N'"';
    EXEC master..xp_cmdshell @Cmd2Exec, NO_OUTPUT;

    SET @Cmd2Exec =
      N'IF EXIST "C:\Program Files\7-Zip\7z.exe" ("C:\Program Files\7-Zip\7z.exe" a -y "' + @OutboundPath + N'\' + @FullName + @ZIP_Extension +
      N'" "' + @OutboundPath + N'\' + @FullName + N'") ELSE (winrar a -ep -m5 "' + @OutboundPath + N'\' + @FullName + @ZIP_Extension +
      N'" "' + @OutboundPath + N'\' + @FullName + N'")';
    EXEC master..xp_cmdshell @Cmd2Exec;

    TRUNCATE TABLE #CmdOut;
    SET @Cmd2Exec = N'IF EXIST "' + @OutboundPath + N'\' + @FullName + @ZIP_Extension + N'" (ECHO ZIP_OK) ELSE (ECHO ZIP_FAIL)';
    INSERT #CmdOut EXEC master..xp_cmdshell @Cmd2Exec;
    IF EXISTS (SELECT 1 FROM #CmdOut WHERE [line] LIKE '%ZIP_OK%') SET @DidZIP = 1;
  END

 -----------------------------------------------------------------------
-- 7) SFTP via PuTTY PSFTP (with pinned host key)
-----------------------------------------------------------------------
IF @OPT_FTP = 1
BEGIN
    IF (ISNULL(@FTP_Server,'') = '' OR ISNULL(@FTP_UserID,'') = '' OR ISNULL(@FTP_Password,'') = '')
    BEGIN
        RAISERROR('SFTP requested but credentials not found in dbo.FTPService (Service=%s). Skipping upload.', 10, 1, @InterfaceName) WITH NOWAIT;
    END
    ELSE
    BEGIN
        DECLARE @ScriptPath NVARCHAR(4000) = @OutboundPath + N'\upload_psftp.txt';
        DECLARE @ToSend NVARCHAR(4000) = @OutboundPath + N'\' + @FullName + CASE WHEN @OPT_ZIP=1 THEN @ZIP_Extension ELSE '' END;

        -- Build the PSFTP script
        SET @Cmd2Exec = N'ECHO lcd "' + @OutboundPath + N'" > "' + @ScriptPath + N'"';
        EXEC master..xp_cmdshell @Cmd2Exec, NO_OUTPUT;
        SET @Cmd2Exec = N'ECHO cd "' + COALESCE(@FTP_RemotePath,'/') + N'" >> "' + @ScriptPath + N'"';
        EXEC master..xp_cmdshell @Cmd2Exec, NO_OUTPUT;
        SET @Cmd2Exec = N'ECHO binary >> "' + @ScriptPath + N'"';
        EXEC master..xp_cmdshell @Cmd2Exec, NO_OUTPUT;
        SET @Cmd2Exec = N'ECHO put "' + @ToSend + N'" >> "' + @ScriptPath + N'"';
        EXEC master..xp_cmdshell @Cmd2Exec, NO_OUTPUT;
        SET @Cmd2Exec = N'ECHO bye >> "' + @ScriptPath + N'"';
        EXEC master..xp_cmdshell @Cmd2Exec, NO_OUTPUT;

        -- Use -hostkey to bypass registry trust and securely pin the known fingerprint
        SET @Cmd2Exec =
            N'cmd /c ""C:\Program Files\PuTTY\psftp.exe" -batch -be -pw "' + @FTP_Password + N'" ' +
            N'-hostkey "ssh-ed25519 255 SHA256:cB4qUeog7B/nonH699a1ZOrZWy3tmGAVytxy8DEj2I0" ' +
            @FTP_UserID + N'@' + @FTP_Server + N' -b "' + @ScriptPath + N'" && ECHO SFTP_OK || ECHO SFTP_FAIL""';

        PRINT 'Running SFTP command: ' + @Cmd2Exec;

        TRUNCATE TABLE #CmdOut;
        INSERT #CmdOut EXEC master..xp_cmdshell @Cmd2Exec;

        SELECT [line] FROM #CmdOut;

        IF EXISTS (SELECT 1 FROM #CmdOut WHERE [line] LIKE '%SFTP_OK%')
            SET @DidFTP = 1;
        ELSE
            RAISERROR('SFTP upload failed (psftp). Check credentials, path, or key.', 16, 1);

        -- Clean up script
        SET @Cmd2Exec = N'DEL /Q "' + @ScriptPath + N'"';
        EXEC master..xp_cmdshell @Cmd2Exec, NO_OUTPUT;
    END
END

-----------------------------------------------------------------------
-- 7B) SECOND UPLOAD — DealerImagePro (FTP via curl)
-----------------------------------------------------------------------
IF @OPT_FTP = 1
BEGIN
    DECLARE
        @DIP_Server       VARCHAR(255),
        @DIP_UserID       VARCHAR(255),
        @DIP_Password     VARCHAR(255),
        @DIP_RemotePath   VARCHAR(255),
        @DIP_ToSend       NVARCHAR(4000),
        @DIP_URL          NVARCHAR(4000);

    -- Read DealerImagePro FTP credentials
    SELECT
        @DIP_Server     = [Server],
        @DIP_UserID     = [UserID],
        @DIP_Password   = [Password],
        @DIP_RemotePath = [RemotePath]
    FROM dbo.FTPService
    WHERE Service = 'DealerImagePro'
      AND LocationID = ISNULL(@FTPLocation_ID, 0);

    IF @@ROWCOUNT = 0
    BEGIN
        SELECT
            @DIP_Server     = [Server],
            @DIP_UserID     = [UserID],
            @DIP_Password   = [Password],
            @DIP_RemotePath = [RemotePath]
        FROM dbo.FTPService
        WHERE Service = 'DealerImagePro'
          AND LocationID = 0;
    END

    IF ISNULL(@DIP_Server,'') = '' OR ISNULL(@DIP_UserID,'') = '' OR ISNULL(@DIP_Password,'') = ''
    BEGIN
        RAISERROR('DealerImagePro FTP credentials not found. Skipping DIP upload.', 10, 1);
    END
    ELSE
    BEGIN
        SET @DIP_ToSend =
            @OutboundPath + '\' + @FullName + CASE WHEN @OPT_ZIP = 1 THEN @ZIP_Extension ELSE '' END;

        -- Build FTP URL
        SET @DIP_URL =
            'ftp://' + @DIP_Server + '/' +
            COALESCE(@DIP_RemotePath,'') + '/' +
            @FullName + CASE WHEN @OPT_ZIP = 1 THEN @ZIP_Extension ELSE '' END;

        -------------------------------------------------------------------
        -- cURL upload (PASSIVE FTP, binary)
        -------------------------------------------------------------------
        SET @Cmd2Exec =
            'cmd /c curl.exe -v -T "' + @DIP_ToSend +
            '" -u "' + @DIP_UserID + ':' + @DIP_Password +
            '" "' + @DIP_URL + '" --ftp-create-dirs --disable-epsv';

        PRINT 'Running DealerImagePro FTP command: ' + @Cmd2Exec;

        TRUNCATE TABLE #CmdOut;
        INSERT #CmdOut EXEC master..xp_cmdshell @Cmd2Exec;

        -- Show verbose cURL output
        SELECT [line] FROM #CmdOut;

        -- Detect success
        IF EXISTS (SELECT 1 FROM #CmdOut WHERE [line] LIKE '%226%' OR [line] LIKE '%successful%' OR [line] LIKE '%100%')
        BEGIN
            RAISERROR('DealerImagePro FTP upload successful.', 0, 1) WITH NOWAIT;
        END
        ELSE
        BEGIN
            RAISERROR('DealerImagePro FTP upload FAILED.', 16, 1);
        END
    END
END


  -----------------------------------------------------------------------
  -- 8) EMAIL (optional)
  -----------------------------------------------------------------------
  IF @OPT_EMAIL = 1
  BEGIN
    DECLARE
      @Subject     NVARCHAR(255) = N'OverFuel Wholegood CSV Extract',
      @Body        NVARCHAR(MAX) = N'Please find the attached OverFuel CSV extract.',
      @ToList      VARCHAR(MAX)  = 'mhoppe@masterstransportation.com;jcastilla@masterstransportation.com',
      @AttachPath  VARCHAR(MAX)  = @OutboundPath + '\' + @FullName + CASE WHEN @OPT_ZIP=1 THEN @ZIP_Extension ELSE '' END,
      @MailItemId  INT;

    EXEC msdb.dbo.sp_send_dbmail
      @profile_name     = 'RIMSS Price File Notifications',
      @recipients       = @ToList,
      @subject          = @Subject,
      @body             = @Body,
      @file_attachments = @AttachPath,
      @mailitem_id      = @MailItemId OUTPUT;

    IF @MailItemId IS NOT NULL SET @DidEmail = 1;
  END

  -----------------------------------------------------------------------
  -- 9) Summary + scope + 10-row preview
  -----------------------------------------------------------------------
  SET @FinalFile = @OutboundPath + '\' + @FullName + CASE WHEN @OPT_ZIP=1 THEN @ZIP_Extension ELSE '' END;

  SELECT
      RunServer              = @ServerName,
      Company_ID_Param       = @Company_ID,
      Location_ID_Param      = @Location_ID,
      LocationList_Param     = @LocationList,
      Locations_Selected     = @ScopeCount,
      StagingTable           = 'dbo.WholegoodCSVExtractData_OverFuel',
      HowToViewAllData       = 'SELECT * FROM dbo.WholegoodCSVExtractData_OverFuel',
      OutboundPath           = @OutboundPath,
      OutputFile             = @FinalFile,
      RowsStaged             = @LoadedRows,
      Did_BCP                = @DidBCP,
      Did_ZIP                = @DidZIP,
      Did_SFTP               = @DidFTP,
      Did_Email              = @DidEmail;

  SELECT Location_ID, Company_ID, Location_Name
  FROM #ScopeLocations
  ORDER BY Company_ID, Location_ID;

  SELECT TOP (10) *
  FROM dbo.WholegoodCSVExtractData_OverFuel
  ORDER BY Location_ID, StockNumber;
END
