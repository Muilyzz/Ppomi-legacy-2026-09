// Generation guard prevents a late permission/token/connect response from reviving a stopped session.
export class VoiceLifetime {
  private generation = 0;
  private live = false;
  begin() {
    this.live = true;
    return ++this.generation;
  }
  isCurrent(id: number) {
    return this.live && id === this.generation;
  }
  assert(id: number) {
    if (!this.isCurrent(id)) throw new Error("세션이 종료되었습니다.");
  }
  end() {
    this.live = false;
    ++this.generation;
  }
}
