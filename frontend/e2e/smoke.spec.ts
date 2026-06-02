import { expect, test } from '@playwright/test';

test('homepage loads with app heading', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Nisbah Learning' })).toBeVisible();
});
