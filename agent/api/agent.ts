import {handleRequest} from '../server/handler.js';
// A flagship-model turn can take a minute; the platform default would cut it off.
export const maxDuration = 120;
// One function route avoids platform-specific catch-all matching for nested paths.
export default {
 fetch(request:Request):Promise<Response> {
  const url=new URL(request.url);
  if(url.pathname==='/api/agent') {
   url.pathname=url.searchParams.get('route')??'/unsupported';
   url.search='';
   return handleRequest(new Request(url,request));
  }
  return handleRequest(request);
 }
};
