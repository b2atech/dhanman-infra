# Scripts

This directory contains shell helper scripts for common DevOps tasks.

## Purpose
- Automate backup and restore operations
- Simplify deployment and restart procedures
- Assist with database migrations
- Provide utility scripts for monitoring and maintenance

## Categories

### Backup Scripts
- Database backups (PostgreSQL)
- Configuration backups
- Application data backups

### Deployment Scripts
- Application deployment automation
- Service restart helpers
- Rolling update scripts

### Migration Scripts
- Database migration helpers
- Configuration migration tools
- Data transformation scripts

## Best Practices
- Make scripts idempotent where possible
- Include error handling and logging
- Add usage documentation at the top of each script
- Use meaningful script names (e.g., `backup_postgres.sh`, `deploy_app.sh`)
