export class PathError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = "PathError";
    this.code = code;
  }
}
