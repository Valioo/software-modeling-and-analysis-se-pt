-- Добавяне на праг в Risk_score с валидация
--  - Low < High, Valid_from < Valid_to, съществуващо Action, ниво >= 1
--  - диапазоните не могат да се припокриват (граничните са включени)
--    за периоди, които се пресичат във времето
-- Пример: EXEC dbo.usp_AddRiskThreshold 6, 100, 9999.99, 6, '2027-01-01', '2099-12-31 23:59:59';
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_AddRiskThreshold
    @ActionId      INT,
    @LowThreshold  DECIMAL(18,2),
    @HighThreshold DECIMAL(18,2),
    @RiskLevel     INT,
    @ValidFrom     DATETIME,
    @ValidTo       DATETIME
AS
BEGIN
    SET NOCOUNT ON;
 
    IF NOT EXISTS (SELECT 1 FROM [Action] WHERE Id = @ActionId)
    BEGIN ;THROW 50010, 'Action does not exist.', 1; END;
 
    IF @LowThreshold >= @HighThreshold
    BEGIN ;THROW 50011, 'Low_threshold must be lower than High_threshold.', 1; END;
 
    IF @ValidFrom >= @ValidTo
    BEGIN ;THROW 50012, 'Valid_from must be earlier than Valid_to.', 1; END;
 
    IF @RiskLevel < 1
    BEGIN ;THROW 50013, 'Risk_level must be 1 or higher.', 1; END;
 
    IF EXISTS (SELECT 1
               FROM Risk_score rs
               WHERE rs.Valid_from     <= @ValidTo
                 AND rs.Valid_to       >= @ValidFrom      -- периодите се пресичат
                 AND rs.Low_threshold  <= @HighThreshold
                 AND rs.High_threshold >= @LowThreshold)  -- диапазоните се пресичат
    BEGIN ;THROW 50014, 'The range overlaps an existing threshold valid in the same period.', 1; END;
 
    INSERT INTO Risk_score (Action_Id, Low_threshold, High_threshold, Risk_level, Valid_from, Valid_to)
    VALUES (@ActionId, @LowThreshold, @HighThreshold, @RiskLevel, @ValidFrom, @ValidTo);
 
    SELECT SCOPE_IDENTITY() AS New_Risk_score_Id;
END;
GO


-- Оценка на транзакция
--  1. изпълнява всички правила, активни към момента на транзакцията
--     (Rule_Availability) и записва Rule_Execution
--  2. смята общия скор (fn_GetTransactionScore)
--  3. намира действието/нивото (fn_GetRiskDecision)
--  4. обновява Transaction.Status според нивото
--  5. ако нивото >= @AlertMinLevel -> създава Alert и го разпределя
--     в опашка (Alert_Case_Queue)
-- Защита от дублиране: ако транзакцията вече има Rule_Execution, не прави нищо.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_EvaluateTransaction
    @TransactionId INT,
    @AlertMinLevel INT      = 3,
    @AsOf          DATETIME = NULL,
    @ShowResult    BIT      = 1
AS
BEGIN
    SET NOCOUNT ON;
 
    DECLARE @AccountId INT, @DeviceId INT, @Ts DATETIME, @Amount DECIMAL(18,2),
            @Src VARCHAR(50), @Dst VARCHAR(50);
 
    SELECT @AccountId = Account_Id, @DeviceId = Device_Id, @Ts = [Timestamp],
           @Amount = Amount, @Src = Source_country, @Dst = Destination_country
    FROM [Transaction]
    WHERE Id = @TransactionId;
 
    IF @AccountId IS NULL
    BEGIN
        RAISERROR('Transaction %d does not exist.', 16, 1, @TransactionId);
        RETURN;
    END;
 
    IF EXISTS (SELECT 1 FROM Rule_Execution WHERE Transaction_Id = @TransactionId)
    BEGIN
        RAISERROR('Transaction %d has already been evaluated.', 16, 1, @TransactionId);
        RETURN;
    END;
 
    DECLARE @Now DATETIME = ISNULL(@AsOf, GETDATE());
 
    -- ---------- факти за транзакцията ----------
    -- "по-ранна" транзакция = по-малък Timestamp (или същия Timestamp и по-малко Id)
    DECLARE @Recent INT, @PrevCnt INT, @PrevAvg DECIMAL(18,4), @DeviceSeen INT;
 
    SELECT @Recent = COUNT(*)
    FROM [Transaction] t
    WHERE t.Account_Id = @AccountId
      AND t.[Timestamp] >= DATEADD(MINUTE, -10, @Ts)
      AND (t.[Timestamp] < @Ts OR (t.[Timestamp] = @Ts AND t.Id < @TransactionId));
 
    SELECT @PrevCnt     = COUNT(*),
           @PrevAvg     = AVG(CAST(t.Amount AS DECIMAL(18,4))),
           @DeviceSeen  = ISNULL(MAX(CASE WHEN t.Device_Id = @DeviceId THEN 1 ELSE 0 END), 0)
    FROM [Transaction] t
    WHERE t.Account_Id = @AccountId
      AND (t.[Timestamp] < @Ts OR (t.[Timestamp] = @Ts AND t.Id < @TransactionId));
 
    -- 1900-01-01 е понеделник => остатък 5 = събота, 6 = неделя (независимо от DATEFIRST)
    DECLARE @IsWeekend BIT = CASE WHEN DATEDIFF(DAY, '19000101', @Ts) % 7 >= 5 THEN 1 ELSE 0 END;
 
    BEGIN TRY
        BEGIN TRAN;
 
        -- ---------- 1. изпълнение на правилата ----------
        INSERT INTO Rule_Execution (Transaction_Id, Rule_Id, Is_triggered, Calculated_score)
        SELECT @TransactionId,
               r.Id,
               x.Hit,
               CASE WHEN x.Hit = 1 THEN r.Score_weight ELSE 0 END
        FROM [Rule] r
        CROSS APPLY (
            SELECT CAST(CASE r.Name
                WHEN 'Large Amount'
                    THEN CASE WHEN @Amount >= 10000 THEN 1 ELSE 0 END
                WHEN 'High-Risk Destination Country'
                    THEN CASE WHEN @Dst IN ('Iran','North Korea','Syria','Myanmar','Yemen',
                                            'Venezuela','Afghanistan','Somalia') THEN 1 ELSE 0 END
                WHEN 'Cross-Border Transfer'
                    THEN CASE WHEN @Src <> @Dst THEN 1 ELSE 0 END
                WHEN 'Night-time Transaction'
                    THEN CASE WHEN DATEPART(HOUR, @Ts) < 5 THEN 1 ELSE 0 END
                WHEN 'Rapid Succession'
                    THEN CASE WHEN @Recent >= 2 THEN 1 ELSE 0 END
                WHEN 'New Device for Account'
                    THEN CASE WHEN @PrevCnt > 0 AND @DeviceSeen = 0 THEN 1 ELSE 0 END
                WHEN 'Round Amount'
                    THEN CASE WHEN @Amount >= 1000 AND @Amount % 1000 = 0 THEN 1 ELSE 0 END
                WHEN 'Amount Spike'
                    THEN CASE WHEN @PrevCnt >= 3 AND @Amount > 5 * @PrevAvg THEN 1 ELSE 0 END
                WHEN 'Structuring Pattern'
                    THEN CASE WHEN @Amount >= 9000 AND @Amount < 10000 THEN 1 ELSE 0 END
                WHEN 'Weekend High Value'
                    THEN CASE WHEN @IsWeekend = 1 AND @Amount >= 3000 THEN 1 ELSE 0 END
                ELSE 0 END AS BIT) AS Hit
        ) x
        WHERE EXISTS (SELECT 1 FROM Rule_Availability ra
                      WHERE ra.Rule_Id = r.Id
                        AND @Ts BETWEEN ra.Available_from AND ra.Available_to);
 
        -- ---------- 2. скор и 3. решение ----------
        DECLARE @Score DECIMAL(18,2) = dbo.fn_GetTransactionScore(@TransactionId);
        DECLARE @ActionId INT, @ActionName VARCHAR(100), @Level INT;
 
        SELECT @ActionId = Action_Id, @ActionName = Action_Name, @Level = Risk_level
        FROM dbo.fn_GetRiskDecision(@Score, @Ts);
 
        IF @Level IS NULL
        BEGIN
            DECLARE @ScoreTxt VARCHAR(20) = CAST(@Score AS VARCHAR(20));
            RAISERROR('No risk threshold configured for score %s at the transaction time.', 16, 1,
                      @ScoreTxt);   -- попада в CATCH => rollback
        END;
 
        -- ---------- 4. статус на транзакцията ----------
        DECLARE @NewStatus VARCHAR(50) =
            CASE WHEN @Level <= 2 THEN 'Approved'
                 WHEN @Level = 3  THEN 'Pending Verification'
                 WHEN @Level = 4  THEN 'Under Review'
                 ELSE 'Blocked' END;
 
        UPDATE [Transaction] SET Status = @NewStatus WHERE Id = @TransactionId;
 
        -- ---------- 5. аларма и опашка ----------
        DECLARE @AlertId INT = NULL, @AlertCreated BIT = 0;
 
        IF @Level >= @AlertMinLevel
           AND NOT EXISTS (SELECT 1 FROM Alert WHERE Transaction_Id = @TransactionId)
        BEGIN
            INSERT INTO Alert (Transaction_Id, Status, Created_at)
            VALUES (@TransactionId, 'New', @Now);
            SET @AlertId = SCOPE_IDENTITY();
            SET @AlertCreated = 1;
 
            -- основна опашка: активна опашка с приоритет най-близък до (7 - ниво)
            -- ниво 6 -> приоритет 1 (най-спешна), ниво 3 -> приоритет 4
            DECLARE @QueueId INT;
            SELECT TOP (1) @QueueId = Id
            FROM Case_Queue
            WHERE Is_active = 1
            ORDER BY ABS(Priority - (7 - @Level)), Id;
 
            IF @QueueId IS NOT NULL
                INSERT INTO Alert_Case_Queue (Alert_Id, Queue_Id, Assigned_at)
                VALUES (@AlertId, @QueueId, @Now);
 
            -- допълнителна опашка (М:Н): рискова държава => AML Screening
            IF EXISTS (SELECT 1
                       FROM Rule_Execution re
                       JOIN [Rule] r ON r.Id = re.Rule_Id
                       WHERE re.Transaction_Id = @TransactionId
                         AND re.Is_triggered = 1
                         AND r.Name = 'High-Risk Destination Country')
            BEGIN
                DECLARE @AmlQueueId INT;
                SELECT @AmlQueueId = Id FROM Case_Queue
                WHERE Name = 'AML Screening' AND Is_active = 1;
 
                IF @AmlQueueId IS NOT NULL AND ISNULL(@AmlQueueId, -1) <> ISNULL(@QueueId, -2)
                    INSERT INTO Alert_Case_Queue (Alert_Id, Queue_Id, Assigned_at)
                    VALUES (@AlertId, @AmlQueueId, @Now);
            END;
        END;
 
        COMMIT TRAN;
 
        IF @ShowResult = 1
            SELECT @TransactionId AS Transaction_Id,
                   @Score         AS Total_score,
                   @ActionName    AS [Action],
                   @Level         AS Risk_level,
                   @NewStatus     AS Transaction_status,
                   @AlertCreated  AS Alert_created,
                   @AlertId       AS Alert_Id;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        THROW;
    END CATCH;
END;
GO