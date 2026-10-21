# RiskManagementPlatform

Курсова работа по софтуерен анализ: платформа за оценка на риск при банкови транзакции (SQL Server).

Системата прилага правила за измама, изчислява риск-скор, взема решение (действие + ниво), обновява статуса на транзакцията и при нужда създава аларма в опашка за анализатори.

## Как се пуска (подред)

Изисква се **SQL Server** (SSMS, Azure Data Studio или `sqlcmd`).

> Ако базата вече съществува и искаш чисто презареждане:  
> `DROP DATABASE RiskManagementPlatform;` и после стъпките отначало.

### 1. Схема

Изпълни `create_db_tables.sql`  
→ създава БД и 11 таблици.

### 2. Обекти (върху `RiskManagementPlatform`)

Изпълни **по ред**:

1. `functions.sql`
2. `stored-procedures.sql`
3. `triggers.sql`

### 3. Данни

Изпълни `data.sql`  
→ пълни каталози, правила, прагове, опашки и транзакции със статус `Pending`.  
`Rule_Execution`, `Alert` и `Alert_Case_Queue` остават празни до следващата стъпка.

### 4. Оценка и симулация

Изпълни `run_evaluation.sql`:

1. За всяка неоценена транзакция вика `usp_EvaluateTransaction`
2. Симулира анализатори (`In Review` / затваряне на аларми → тригерът обновява `Transaction.Status`)
3. Показва проверки (броячи по статус, опашки, топ 10 рискови транзакции)

## Как работи платформата

```
Transaction (Pending)
        │
        ▼
usp_EvaluateTransaction
        │
        ├─► Rule_Availability → активни правила към Timestamp
        ├─► Rule_Execution    → кои правила се задействат + тегло
        ├─► fn_GetTransactionScore → сума на задействалите се
        ├─► fn_GetRiskDecision     → Action + Risk_level по прагове
        ├─► Transaction.Status     → Approved / Pending Verification / Under Review / Blocked
        └─► (ако ниво ≥ 3) Alert + Alert_Case_Queue
                    │
                    ▼
            анализатор променя Alert.Status
                    │
                    ▼
            trg_Alert_StatusChange → обновява Transaction
```

### Функции

| Функция | Тип | Какво прави |
|---------|-----|-------------|
| `fn_GetTransactionScore(@TransactionId)` | скаларна | Сума на `Calculated_score` от `Rule_Execution`, където `Is_triggered = 1` (иначе 0) |
| `fn_GetRiskDecision(@Score, @AtDate)` | таблична (TVF) | Намира ред в `Risk_score` с `Low ≤ скор ≤ High` и валиден период; връща действие и ниво |

### Процедури

| Процедура | Какво прави |
|-----------|-------------|
| `usp_EvaluateTransaction` | Пълен пайплайн: правила → скор → решение → статус → евентуална аларма/опашка |
| `usp_AddRiskThreshold` | Добавя праг в `Risk_score` с валидация (Low &lt; High, дати, Action, без припокриване) |

### Тригери

| Тригер | Какво прави |
|--------|-------------|
| `trg_Alert_StatusChange` | Валидни статуси; затворена аларма е заключена; Confirmed Fraud → Blocked, False Positive → Approved |
| `trg_AlertCaseQueue_Insert` | Само активна опашка; не затворена аларма; `New` → `Assigned` |

### Правила (тегла)

| Правило | Тегло | Условие (накратко) |
|---------|-------|-------------------|
| Large Amount | 30 | сума ≥ 10 000 |
| High-Risk Destination Country | 25 | рискова държава получател |
| Cross-Border Transfer | 10 | изпращач ≠ получател |
| Night-time Transaction | 10 | час &lt; 5 |
| Rapid Succession | 20 | ≥ 2 по-ранни tx в последните 10 мин |
| New Device for Account | 15 | сметката има история, устройството е ново |
| Round Amount | 8 | ≥ 1000 и кратно на 1000 |
| Amount Spike | 20 | ≥ 3 предишни и сума &gt; 5× средната |
| Structuring Pattern | 25 | 9000 ≤ сума &lt; 10000 |
| Weekend High Value | 12 | събота/неделя и сума ≥ 3000 |

Праговете в `Risk_score` са исторически: до 30.06.2026 — 3 нива; от 01.07.2026 — 6 нива. Границите са **включителни**.

## Полезни тестове

```sql
-- Скор на транзакция
SELECT dbo.fn_GetTransactionScore(11);

-- Решение за скор към дата
SELECT * FROM dbo.fn_GetRiskDecision(62.00, GETDATE());

-- Оценка на една транзакция
EXEC dbo.usp_EvaluateTransaction @TransactionId = 1, @ShowResult = 1;

-- Трябва да хвърли грешка (припокриващ се праг)
EXEC dbo.usp_AddRiskThreshold 3, 40, 60, 3, '2026-07-01', '2099-12-31 23:59:59';
```