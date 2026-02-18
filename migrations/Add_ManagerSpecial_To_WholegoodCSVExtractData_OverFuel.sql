USE [WinNetStarApp]
GO

-- Add ManagerSpecial column (UDF_ID 124) to the OverFuel staging table
IF NOT EXISTS (
    SELECT 1
    FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.WholegoodCSVExtractData_OverFuel')
      AND name = 'ManagerSpecial'
)
BEGIN
    ALTER TABLE dbo.WholegoodCSVExtractData_OverFuel
        ADD ManagerSpecial NVARCHAR(MAX) NULL;

    PRINT 'Column ManagerSpecial added to dbo.WholegoodCSVExtractData_OverFuel.';
END
ELSE
BEGIN
    PRINT 'Column ManagerSpecial already exists on dbo.WholegoodCSVExtractData_OverFuel. No change made.';
END
GO
