flowchart TD
%% Author: @dapkor
%% MEAM – Presentation Diagram (Stakeholder View)

    classDef t0 fill:#5a1010,stroke:#ff5757,stroke-width:2px,color:#fff;
    classDef t1 fill:#102a5a,stroke:#5aa0ff,stroke-width:2px,color:#fff;
    classDef t2 fill:#124a12,stroke:#63d963,stroke-width:2px,color:#fff;
    classDef sec fill:#242424,stroke:#f3c64b,stroke-width:1px,color:#f3c64b,stroke-dasharray: 4 4;
    classDef ops fill:#0d2a3a,stroke:#3dc7ff,stroke-width:2px,color:#d8f3ff;

    PRINCIPLE["Clean Source Principle"]

    subgraph T0 ["Tier 0 - Identity Core"]
        PAW0["PAW-T0"]
        Z0A["Zone 0A\nDomain Controllers & PKI"]
        Z0B["Zone 0B\nVirtualization Fabric"]
        SILO0["Auth Silos 0A-0B"]
        BG["Break-Glass\nEmergency Only"]
    end

    subgraph T1 ["Tier 1 - Server Management"]
        PAW1["PAW-T1"]
        Z1A["Zone 1A\nEndpoint Management"]
        Z1B["Zone 1B\nApp & File Servers"]
        Z1C["Zone 1C\nDNS / NPS"]
        Z1D["Zone 1D\nStorage Management"]
        SILO1["Auth Silos 1A-1D"]
    end

    subgraph T2 ["Tier 2 - User Workloads"]
        PAW2["PAW-T2"]
        Z2A["Zone 2A\nWorkstations"]
        Z2B["Zone 2B\nBusiness Servers"]
        SILO2["Auth Silo 2A"]
    end

    subgraph SEC ["Security Controls"]
        FAST{{"Kerberos Armoring (FAST)"}}
        GPO{{"Cross-Tier Deny Logon"}}
        PU{{"Protected Users"}}
        PSO{{"Password Policies (PSO)"}}
        LAPS{{"LAPS"}}
    end

    subgraph OPS ["Monitoring & Reporting"]
        SVC["svc-meam-report\nRead-Only"]
        SCAN["Auto-Tiering Scanner"]
        RPT["Monthly HTML Report"]
        PIPE["GitHub Actions / Azure DevOps"]
    end

    PAW0 --> SILO0
    PAW1 --> SILO1
    PAW2 --> SILO2

    PAW0 --> Z0A & Z0B
    PAW1 --> Z1A & Z1B & Z1C & Z1D
    PAW2 --> Z2A & Z2B

    T1 -.->|"No upward admin path"| T0
    T2 -.->|"No upward admin path"| T1
    BG -.->|"Emergency path"| Z0A

    FAST -.-> SILO0 & SILO1 & SILO2
    GPO -.-> T0 & T1 & T2
    PU -.-> T0 & T1
    PSO -.-> T0 & T1 & T2
    LAPS -.-> T1 & T2

    SVC --> Z0A
    SVC --> SCAN & RPT
    PIPE --> RPT
    RPT -.-> PIPE

    PRINCIPLE -.-> T0

    class PAW0,Z0A,Z0B,SILO0,BG t0;
    class PAW1,Z1A,Z1B,Z1C,Z1D,SILO1 t1;
    class PAW2,Z2A,Z2B,SILO2 t2;
    class FAST,GPO,PU,PSO,LAPS sec;
    class SVC,SCAN,RPT,PIPE ops;