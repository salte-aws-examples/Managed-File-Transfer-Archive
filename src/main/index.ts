/**
 * Serverless function handler for Managed-File-Transfer-Archive
 */
export async function handler(event: any, context: any) {
  console.log('Event:', JSON.stringify(event, null, 2));
  console.log('Context:', JSON.stringify(context, null, 2));
  
  return {
    statusCode: 200,
    body: JSON.stringify({ message: 'Hello World!' }),
  };
}
