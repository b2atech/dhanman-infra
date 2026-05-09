# Rclone Config

Place deployment-specific `rclone.conf` material outside Git.

Recommended approach:

- Keep a template in automation or secret management.
- Mount or copy the real config during deployment.
- Use this directory only for documentation and non-secret examples.
