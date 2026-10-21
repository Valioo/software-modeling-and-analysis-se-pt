CREATE DATABASE RiskManagementPlatform;
GO

USE RiskManagementPlatform;
GO

CREATE TABLE Device (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Type VARCHAR(50) NOT NULL
);

CREATE TABLE Account (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Type VARCHAR(50) NOT NULL
);

CREATE TABLE [Rule] (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Name VARCHAR(100) NOT NULL,
    Score_weight DECIMAL(5,2) NOT NULL
);

CREATE TABLE Action (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Name VARCHAR(100) NOT NULL
);

CREATE TABLE Case_Queue (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Name VARCHAR(100) NOT NULL,
    Priority INT NOT NULL,
    Is_active BIT NOT NULL
);

CREATE TABLE [Transaction] (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Account_Id INT NOT NULL,
    Device_Id INT NOT NULL,
    [Timestamp] DATETIME DEFAULT GETDATE(), -- Поставено в скоби за сигурност
    Amount DECIMAL(18,2) NOT NULL,
    Currency VARCHAR(3) NOT NULL,
    Status VARCHAR(50) NOT NULL,
    Source_country VARCHAR(50),
    Destination_country VARCHAR(50),
    FOREIGN KEY (Account_Id) REFERENCES Account(Id),
    FOREIGN KEY (Device_Id) REFERENCES Device(Id)
);

CREATE TABLE Rule_Availability (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Rule_Id INT NOT NULL,
    Available_from DATETIME NOT NULL,
    Available_to DATETIME NOT NULL,
    FOREIGN KEY (Rule_Id) REFERENCES [Rule](Id)
);

CREATE TABLE Risk_score (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Action_Id INT NOT NULL,
    Low_threshold DECIMAL(18,2) NOT NULL,
    High_threshold DECIMAL(18,2) NOT NULL,
    Risk_level INT NOT NULL,
    Valid_from DATETIME NOT NULL,
    Valid_to DATETIME NOT NULL,
    FOREIGN KEY (Action_Id) REFERENCES Action(Id)
);

CREATE TABLE Rule_Execution (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Transaction_Id INT NOT NULL,
    Rule_Id INT NOT NULL,
    Is_triggered BIT NOT NULL,
    Calculated_score DECIMAL(18,2) NOT NULL,
    FOREIGN KEY (Transaction_Id) REFERENCES [Transaction](Id),
    FOREIGN KEY (Rule_Id) REFERENCES [Rule](Id)
);

CREATE TABLE Alert (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Transaction_Id INT UNIQUE NOT NULL,
    Status VARCHAR(50) NOT NULL,
    Created_at DATETIME DEFAULT GETDATE(),
    FOREIGN KEY (Transaction_Id) REFERENCES [Transaction](Id)
);

CREATE TABLE Alert_Case_Queue (
    Alert_Id INT NOT NULL,
    Queue_Id INT NOT NULL,
    Assigned_at DATETIME DEFAULT GETDATE(),
    PRIMARY KEY (Alert_Id, Queue_Id),
    FOREIGN KEY (Alert_Id) REFERENCES Alert(Id),
    FOREIGN KEY (Queue_Id) REFERENCES Case_Queue(Id)
);