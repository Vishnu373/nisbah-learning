import { render, screen } from '@testing-library/react';

import { App } from '../App';

describe('App smoke', () => {
  it('renders the app heading', () => {
    render(<App />);
    expect(screen.getByRole('heading', { name: 'Nisbah Learning' })).toBeInTheDocument();
  });
});
