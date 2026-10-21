-- Сума на Calculated_score на задействалите се правила.
CREATE OR ALTER FUNCTION dbo.fn_GetTransactionScore (@TransactionId INT)
RETURNS DECIMAL(18,2)
AS
BEGIN
    DECLARE @Score DECIMAL(18,2);
 
    SELECT @Score = ISNULL(SUM(Calculated_score), 0)
    FROM Rule_Execution
    WHERE Transaction_Id = @TransactionId
      AND Is_triggered = 1;
 
    RETURN ISNULL(@Score, 0);
END;
GO

-- какво решение съответства на даден скор към дадена дата
-- Граници: Low <= скор <= High (включително от двете страни).
CREATE OR ALTER FUNCTION dbo.fn_GetRiskDecision (@Score DECIMAL(18,2), @AtDate DATETIME)
RETURNS TABLE
AS
RETURN
(
    SELECT TOP (1)
           rs.Id        AS Risk_score_Id,
           rs.Action_Id AS Action_Id,
           a.Name       AS Action_Name,
           rs.Risk_level AS Risk_level
    FROM Risk_score rs
    JOIN [Action] a ON a.Id = rs.Action_Id
    WHERE @Score  BETWEEN rs.Low_threshold AND rs.High_threshold
      AND @AtDate BETWEEN rs.Valid_from    AND rs.Valid_to
    ORDER BY rs.Risk_level DESC
);
GO