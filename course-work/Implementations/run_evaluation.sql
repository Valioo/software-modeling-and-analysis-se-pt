-- Пуска usp_EvaluateTransaction за всички транзакции (по ред), после
-- симулира работа на анализаторите (затваряне на аларми -> тригер 1).
USE RiskManagementPlatform;
GO
SET NOCOUNT ON;

-- 1) Оценка на всички още неоценени транзакции
DECLARE @Id INT, @Ts DATETIME, @Now DATETIME;

DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT t.Id, t.[Timestamp]
    FROM [Transaction] t
    WHERE NOT EXISTS (SELECT 1 FROM Rule_Execution re WHERE re.Transaction_Id = t.Id)
    ORDER BY t.Id;

OPEN c;
FETCH NEXT FROM c INTO @Id, @Ts;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Now = DATEADD(SECOND, 2, @Ts);   -- аларма 2 сек. след транзакцията
    EXEC dbo.usp_EvaluateTransaction @TransactionId = @Id, @AsOf = @Now, @ShowResult = 0;
    FETCH NEXT FROM c INTO @Id, @Ts;
END;
CLOSE c;
DEALLOCATE c;
GO

-- 2) Анализаторите: по-новите аларми са "In Review"
UPDATE Alert
SET Status = 'In Review'
WHERE Created_at >= '2026-10-10' AND Status = 'Assigned' AND Id % 2 = 0;

-- 3) По-старите аларми са затворени (тригерът обновява и Transaction.Status)
UPDATE a
SET Status = CASE
        WHEN t.Status = 'Blocked'      THEN CASE WHEN a.Id % 5  = 0 THEN 'False Positive' ELSE 'Confirmed Fraud' END
        WHEN t.Status = 'Under Review' THEN CASE WHEN a.Id % 10 < 7 THEN 'False Positive' ELSE 'Confirmed Fraud' END
        ELSE                                CASE WHEN a.Id % 10 = 0 THEN 'Confirmed Fraud' ELSE 'False Positive' END
    END
FROM Alert a
JOIN [Transaction] t ON t.Id = a.Transaction_Id
WHERE a.Created_at < '2026-10-10';
GO
