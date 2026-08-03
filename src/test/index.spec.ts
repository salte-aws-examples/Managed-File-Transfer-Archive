import { handler } from '../main/index';

describe('Managed-File-Transfer-Archive', () => {
  it('should return Hello World!', async () => {
    const event = {};
    const context = {};
    const result = await handler(event, context);
    
    expect(result.statusCode).toBe(200);
    const body = JSON.parse(result.body);
    expect(body.message).toBe('Hello World!');
  });
});
