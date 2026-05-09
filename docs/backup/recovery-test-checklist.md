# Recovery Test Checklist

- Verify the selected backup exists in remote storage.
- Verify database restore completes without schema errors.
- Verify file restore completes without permission errors.
- Verify core application services start.
- Verify application health endpoints respond.
- Verify one representative read path per major module.
- Record timing, issues, and follow-up fixes.
