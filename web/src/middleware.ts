import { clerkMiddleware, createRouteMatcher } from '@clerk/nextjs/server';
import { NextResponse, type NextMiddleware } from 'next/server';
import { isClerkConfigured } from '@/lib/clerk-env';

const isProtectedRoute = createRouteMatcher(['/account(.*)']);

const live: NextMiddleware = clerkMiddleware(async (auth, request) => {
  if (isProtectedRoute(request)) await auth.protect();
});

const setup: NextMiddleware = () => NextResponse.next();

/** Decided per request so a key added or fixed at runtime is honoured without a rebuild. */
const middleware: NextMiddleware = (request, event) =>
  (isClerkConfigured() ? live : setup)(request, event);

export default middleware;

export const config = {
  matcher: [
    '/((?!_next|[^?]*\\.(?:html?|css|js(?!on)|jpe?g|webp|png|gif|svg|ttf|woff2?|ico|csv|docx?|xlsx?|zip|webmanifest)).*)',
    '/(api|trpc)(.*)',
    '/__clerk/(.*)',
  ],
};
