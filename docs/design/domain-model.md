# Domain model

Core entities of the support automation domain and the ticket lifecycle they revolve around.

## Entities

```mermaid
classDiagram
    class Ticket {
        +string id
        +string subject
        +string body
        +string language
        +string intent
        +string sentiment
        +TicketStatus status
        +datetime createdAt
    }
    class Customer {
        +string id
        +string name
        +string email
    }
    class Booking {
        +string id
        +string reference
        +string status
        +datetime travelDate
        +decimal amount
    }
    class Refund {
        +string id
        +decimal amount
        +string status
        +datetime requestedAt
    }
    class Agent {
        +string id
        +string name
        +string team
    }

    Customer "1" --> "*" Ticket : raises
    Customer "1" --> "*" Booking : owns
    Ticket "0..1" --> "1" Booking : concerns
    Booking "1" --> "0..*" Refund : may trigger
    Agent "0..1" --> "*" Ticket : handles
```

A ticket is raised by a customer and may concern one of their bookings. Refund tickets lead to a
refund against that booking. An agent is assigned only when the ticket is escalated to a human.

## Ticket status state machine

```mermaid
stateDiagram-v2
    [*] --> NEW
    NEW --> CLASSIFIED : classifier or fallback assigns intent
    CLASSIFIED --> ROUTED : DMN routing decision
    ROUTED --> IN_PROGRESS : work started
    IN_PROGRESS --> RESOLVED : automated handling succeeded
    IN_PROGRESS --> ESCALATED : guardrail or handling failure, human takes over
    RESOLVED --> CLOSED
    ESCALATED --> CLOSED
    CLOSED --> [*]
```
