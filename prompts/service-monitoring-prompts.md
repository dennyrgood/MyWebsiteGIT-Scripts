# Service Monitoring Prompts

## Prompt 1: Core Design
Design and implement the core functionality for a Python program to monitor multiple services for their health and availability. The program should support both 'local' and 'remote' service monitoring, based on a configuration stored in a JSON file. Implement the following:
- Parse a JSON file defining services to monitor with fields for:
  - `name` (service name),
  - `endpoint` (URL with port),
  - `type` (`standalone`, `flask`, `external`),
  - `mode` (`local` or `remote`),
  - `check` (specifications like `route` or `expected output` for health checks),
  - `interval` (frequency of checks in seconds).
- Periodically check the services by sending requests to their endpoints:
  - Confirm availability using HTTP status codes (200 = healthy) or expected outputs.
  - Handle transient failures with retries before marking a service as 'down.'
- Log all service statuses to the console, and include timestamps for each check.
- (Asynchronous Approach): Use `asyncio` or similar to avoid delays when checking multiple services.
- Test the program using mock endpoints or test services.

## Prompt 2: Introduce the GUI Dashboard
Build a simple graphical dashboard for the service monitoring application. Use Tkinter or another appropriate cross-platform Python GUI library such as PyQt. The dashboard should:
- Display real-time statuses for each service monitored by the core program.
- Use a color-coded system for service health:
  - **Green**: Service is healthy,
  - **Yellow**: Service is degraded but responsive,
  - **Red**: Service is down/unresponsive.
- Include a column for:
  - Service name,
  - Endpoint (URL),
  - Status (Up/Degraded/Down),
  - Last check time (timestamp).
- Automatically refresh the dashboard at regular intervals to display updated service statuses.
- Support grouping services into categories:
  - `local` and `remote`,
  - `standalone`, `flask`, and `external`.
- Implement an error/alert indicator (e.g., a separate section for disconnected services).
- Retain all logging functionality, and output changes to both the console and the dashboard for debugging purposes.
- Place visual placeholders or future extension notes for 'text' and 'email' notifications but leave them unimplemented at this stage.

## Prompt 3: Polishing and Advanced Features
Enhance and polish the existing program to add advanced and optional features. Implement the following:
- **Resource Monitoring (Local-only):**
  - Check CPU, memory, and network usage for local services, and display these stats alongside the service statuses in the dashboard.
- **Embedded Web Dashboard:**
  - Include a lightweight web server (using Flask or FastAPI) to mirror the dashboard’s status display in a browser.
- **Data Logging and Export:**
  - Store historical data logs in a CSV or JSON file and include a GUI option to export logs on demand.
- **Crash Recovery:**
  - If the program crashes, implement logic to start monitoring from where it left off by reloading previous states from the logs.
- **UI Polishing:**
  - Add modern visual designs (e.g., tooltips, hoverable details) to the dashboard to display additional service information (e.g., response time).
- **Future-Proofing for Notifications:**
  - Clearly mark unused code sections intended for implementing 'text' and 'email' notifications in the future, with placeholder comments to indicate where these features would integrate.
- Optimize for cross-platform compatibility and ensure that everything works seamlessly on both Windows 11 and MacOS.
