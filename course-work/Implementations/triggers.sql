
-- Промяна на статус на аларма
--  - позволени статуси: New, Assigned, In Review, Confirmed Fraud, False Positive
--  - затворена аларма (Confirmed Fraud / False Positive) не може да се променя
--  - при затваряне се обновява статусът на транзакцията:
--      Confirmed Fraud -> Blocked,  False Positive -> Approved
-- =====================================================================
CREATE OR ALTER TRIGGER dbo.trg_Alert_StatusChange
ON Alert
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(Status) RETURN;
 
    IF EXISTS (SELECT 1 FROM inserted
               WHERE Status NOT IN ('New','Assigned','In Review','Confirmed Fraud','False Positive'))
    BEGIN
        ROLLBACK TRANSACTION;
        THROW 50020, 'Invalid alert status.', 1;
    END;
 
    IF EXISTS (SELECT 1
               FROM inserted i
               JOIN deleted d ON d.Id = i.Id
               WHERE d.Status IN ('Confirmed Fraud','False Positive')
                 AND i.Status <> d.Status)
    BEGIN
        ROLLBACK TRANSACTION;
        THROW 50021, 'A closed alert cannot be reopened or changed.', 1;
    END;
 
    UPDATE t
    SET t.Status = CASE i.Status WHEN 'Confirmed Fraud' THEN 'Blocked' ELSE 'Approved' END
    FROM [Transaction] t
    JOIN inserted i ON i.Transaction_Id = t.Id
    JOIN deleted  d ON d.Id = i.Id
    WHERE i.Status IN ('Confirmed Fraud','False Positive')
      AND d.Status <> i.Status;
END;
GO
 
-- Разпределяне на аларма в опашка
--  - опашката трябва да е активна (Is_active = 1)
--  - не може да се разпределя затворена аларма
--  - алармата със статус New автоматично става Assigned
-- =====================================================================
CREATE OR ALTER TRIGGER dbo.trg_AlertCaseQueue_Insert
ON Alert_Case_Queue
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
 
    IF EXISTS (SELECT 1 FROM inserted i
               JOIN Case_Queue q ON q.Id = i.Queue_Id
               WHERE q.Is_active = 0)
    BEGIN
        ROLLBACK TRANSACTION;
        THROW 50030, 'Cannot assign an alert to an inactive queue.', 1;
    END;
 
    IF EXISTS (SELECT 1 FROM inserted i
               JOIN Alert a ON a.Id = i.Alert_Id
               WHERE a.Status IN ('Confirmed Fraud','False Positive'))
    BEGIN
        ROLLBACK TRANSACTION;
        THROW 50031, 'Cannot assign a closed alert to a queue.', 1;
    END;
 
    UPDATE a
    SET a.Status = 'Assigned'
    FROM Alert a
    JOIN inserted i ON i.Alert_Id = a.Id
    WHERE a.Status = 'New';
END;
GO
 