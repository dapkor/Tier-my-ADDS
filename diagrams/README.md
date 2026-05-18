# diagrams

## Overview
Architecture diagrams and visual references for the MEAM (Monash Enterprise Access Model) and Tier-my-ADDS project.

## Purpose
This folder contains visual representations of the MEAM tier model, security architecture, and deployment topology for different audiences (technical, executive, presentation).

## Diagrams

### Tier-Architecture.txt
**Technical tier architecture diagram**

Visual representation of the three-tier model:
- **Tier 0 (T0):** Control plane (Domain Controllers, PKI, ADFS)
- **Tier 1 (T1):** Management plane (Management servers, DNS, SCCM)
- **Tier 2 (T2):** Workload plane (User workstations, business servers)

Shows:
- Zone distribution within each tier
- Service deployment per zone
- Trust relationships
- Access flow directions

**Usage:** Technical documentation, reference implementations

### Tier-Architecture-Presentation.md
**Presentation-ready tier architecture**

Markdown-formatted diagram for presentations and slides.
- Simplified visual representation
- Markdown-compatible rendering
- Print-friendly layout

**Usage:** Presentations, stakeholder meetings, training materials

### Tier-Architecture-Executive.txt
**Executive summary diagram**

High-level abstraction of the MEAM model:
- Simplified tier representation
- Risk zones highlighted
- Compliance mapping
- Business impact messaging

**Usage:** Executive briefings, board presentations, business case documentation

## Using Diagrams

### In PowerPoint
1. Copy diagram content from `.txt` or `.md` file
2. Paste into text box or note section
3. Use as reference for creating polished graphics
4. Update corporate branding/colors

### In Documentation
1. Include diagram in markdown documentation
2. Reference with `![Diagram](diagrams/Tier-Architecture.txt)`
3. Provide textual description alongside

### In Presentations
1. Screenshot diagram from markdown viewer
2. Include with presentation slides
3. Reference during architecture discussions
4. Use for training purposes

## Diagram Format

The `.txt` files use ASCII art format:
- Compatible with any text editor
- No special rendering required
- Version control friendly (plain text)
- Copy-paste ready

The `.md` file uses markdown format:
- Enhanced formatting
- Better visual organization
- Suitable for GitHub wikis
- Supports GitHub markdown rendering

## Updating Diagrams

When updating MEAM architecture:

1. **Modify diagram content** in the respective file
2. **Update title** to reflect changes
3. **Version in footer** (YYYY-MM-DD format)
4. **Test rendering** in target format (PowerPoint, markdown viewer)
5. **Commit with message:** "Update: [diagram name] - [change description]"

### Tools for Diagram Updates

- **ASCII Art Creators:** Asciiflow (online), AACircuit (VS Code)
- **Markdown Editors:** VS Code, Markdown Preview Enhanced
- **Version Control:** Git (track all changes)

## Integration

### GitHub Wiki
```markdown
## Architecture Overview

![MEAM Tier Model](../diagrams/Tier-Architecture-Presentation.md)

See full documentation in [ARCHITECTURE.md](../ARCHITECTURE.md)
```

### Documentation
```markdown
# MEAM Security Model

## Visual Overview

\`\`\`
[Diagram content from Tier-Architecture.txt]
\`\`\`

See [Diagram Reference](../diagrams/) for detailed visuals.
```

## Related Documentation

- **Architecture:** [ARCHITECTURE.md](../ARCHITECTURE.md)
- **Deployment:** [1-Deployment/README.md](../1-Deployment/README.md)
- **Operations:** [OPERATIONS.md](../OPERATIONS.md)

---
**Last Updated:** 2024
