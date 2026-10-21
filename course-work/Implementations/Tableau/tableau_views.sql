/* =====================================================================
   tableau_views.sql – изгледи (views) за доклада в Tableau
   ---------------------------------------------------------------------
   Пуска се след run_evaluation.sql (за да има оценени транзакции,
   сигнали и опашки). Изгледите само четат данни – нищо не променят.

   vw_Tableau_Transactions     – 1 ред = 1 транзакция (с риск, решение и сигнал)
   vw_Tableau_Rule_Executions  – 1 ред = 1 правило, изпълнено върху 1 транзакция
   vw_Tableau_Alert_Queues     – 1 ред = 1 сигнал в 1 опашка (връзката M:N)

   Трите изгледа се свързват в Tableau по Transaction_Id.
   ===================================================================== */

USE RiskManagementPlatform;
GO

/* ---------------------------------------------------------------------
   Транзакции.
   Action_Name / Risk_level – решението, взето при оценката (по праговете,
   валидни към момента на транзакцията – fn_GetRiskDecision).
   Transaction_Status – текущият статус; може да се е променил след
   затваряне на сигнала (False Positive -> Approved, Confirmed Fraud -> Blocked).
   За неоценени транзакции Risk_level и Action_Name са празни.
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_Tableau_Transactions
AS
SELECT
    t.Id                                   AS Transaction_Id,
    t.[Timestamp]                          AS Transaction_Time,
    DATEPART(HOUR, t.[Timestamp])          AS Hour_of_day,
    t.Account_Id,
    acc.Type                               AS Account_Type,
    t.Device_Id,
    dev.Type                               AS Device_Type,
    t.Amount,
    t.Currency,
    t.Source_country,
    t.Destination_country,
    CASE WHEN t.Source_country <> t.Destination_country THEN 1 ELSE 0 END AS Is_cross_border,
    t.Status                               AS Transaction_Status,
    CASE WHEN t.Status = 'Blocked' THEN 1 ELSE 0 END AS Is_blocked,
    CASE WHEN sc.Transaction_Id IS NULL THEN 0 ELSE 1 END AS Is_evaluated,
    ISNULL(sc.Total_score, 0)              AS Total_score,
    ISNULL(sc.Triggered_rules_count, 0)    AS Triggered_rules_count,
    d.Risk_level,
    d.Action_Name,
    al.Id                                  AS Alert_Id,
    al.Status                              AS Alert_Status,
    CASE WHEN al.Id IS NULL THEN 0 ELSE 1 END AS Has_alert
FROM [Transaction] AS t
JOIN Account AS acc ON acc.Id = t.Account_Id
JOIN Device  AS dev ON dev.Id = t.Device_Id
LEFT JOIN (
    SELECT Transaction_Id,
           SUM(CASE WHEN Is_triggered = 1 THEN Calculated_score ELSE 0 END) AS Total_score,
           SUM(CASE WHEN Is_triggered = 1 THEN 1 ELSE 0 END)                AS Triggered_rules_count
    FROM Rule_Execution
    GROUP BY Transaction_Id
) AS sc ON sc.Transaction_Id = t.Id
OUTER APPLY dbo.fn_GetRiskDecision(sc.Total_score, t.[Timestamp]) AS d
LEFT JOIN Alert AS al ON al.Transaction_Id = t.Id;
GO

/* ---------------------------------------------------------------------
   Изпълнения на правилата.
   Score_share – какъв дял от общия риск на транзакцията е дало правилото
   (0, ако транзакцията е с 0 точки).
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_Tableau_Rule_Executions
AS
SELECT
    re.Id                                  AS Execution_Id,
    re.Transaction_Id,
    t.[Timestamp]                          AS Transaction_Time,
    r.Name                                 AS Rule_Name,
    r.Score_weight,
    CAST(re.Is_triggered AS INT)           AS Is_triggered,
    re.Calculated_score,
    CAST(CASE WHEN tot.Total_score > 0
              THEN re.Calculated_score / tot.Total_score
              ELSE 0 END AS DECIMAL(9,4))  AS Score_share,
    t.Status                               AS Transaction_Status,
    t.Destination_country
FROM Rule_Execution AS re
JOIN [Rule]         AS r ON r.Id = re.Rule_Id
JOIN [Transaction]  AS t ON t.Id = re.Transaction_Id
CROSS APPLY (
    SELECT SUM(CASE WHEN x.Is_triggered = 1 THEN x.Calculated_score ELSE 0 END) AS Total_score
    FROM Rule_Execution AS x
    WHERE x.Transaction_Id = re.Transaction_Id
) AS tot;
GO

/* ---------------------------------------------------------------------
   Сигнали по опашки (Alert_Case_Queue, M:N).
   Един сигнал може да е в няколко опашки => за брой сигнали в Tableau
   използвайте COUNTD(Alert_Id), а не COUNT.
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_Tableau_Alert_Queues
AS
SELECT
    a.Id                                   AS Alert_Id,
    a.Transaction_Id,
    a.Status                               AS Alert_Status,
    a.Created_at                           AS Alert_Created_at,
    q.Name                                 AS Queue_Name,
    q.Priority                             AS Queue_Priority,
    CAST(q.Is_active AS INT)               AS Queue_Is_active,
    acq.Assigned_at,
    t.Amount,
    t.Currency,
    t.Status                               AS Transaction_Status
FROM Alert            AS a
JOIN Alert_Case_Queue AS acq ON acq.Alert_Id = a.Id
JOIN Case_Queue       AS q   ON q.Id = acq.Queue_Id
JOIN [Transaction]    AS t   ON t.Id = a.Transaction_Id;
GO

-- Проверка
SELECT 'vw_Tableau_Transactions'    AS view_name, COUNT(*) AS row_count FROM dbo.vw_Tableau_Transactions
UNION ALL
SELECT 'vw_Tableau_Rule_Executions', COUNT(*) FROM dbo.vw_Tableau_Rule_Executions
UNION ALL
SELECT 'vw_Tableau_Alert_Queues',    COUNT(*) FROM dbo.vw_Tableau_Alert_Queues;
GO
