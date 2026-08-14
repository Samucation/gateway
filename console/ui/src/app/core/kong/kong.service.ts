import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';
import { environment } from '../../../environments/environment';

export interface KongCollection<T> { data: T[]; offset?: string; next?: string; }

export interface KongService {
  id: string; name: string; host: string; port: number; protocol: string;
  path?: string; retries: number; connect_timeout: number; write_timeout: number;
  read_timeout: number; tags?: string[]; enabled: boolean;
  created_at: number; updated_at: number;
}
export interface KongRoute {
  id: string; name?: string; protocols: string[]; methods?: string[];
  hosts?: string[]; paths?: string[]; strip_path: boolean; preserve_host: boolean;
  service: { id: string }; tags?: string[];
  created_at: number; updated_at: number;
}
export interface KongPlugin {
  id: string; name: string; enabled: boolean;
  service?: { id: string }; route?: { id: string }; consumer?: { id: string };
  config: Record<string, unknown>; tags?: string[];
  created_at: number;
}
export interface KongConsumer {
  id: string; username?: string; custom_id?: string; tags?: string[];
  created_at: number;
}
export interface KongUpstream {
  id: string; name: string; algorithm: string; slots: number;
  hash_on?: string; tags?: string[]; created_at: number;
}
export interface KongTarget {
  id: string; target: string; weight: number; upstream: { id: string };
  tags?: string[]; created_at: number;
}
export interface KongInfo {
  version: string; hostname: string; tagline: string;
  plugins: { available_on_server: Record<string, unknown>; enabled_in_cluster: string[] };
  configuration: Record<string, unknown>;
}

@Injectable({ providedIn: 'root' })
export class KongApi {
  private http = inject(HttpClient);
  private base = environment.api.kong;

  info(): Observable<KongInfo> { return this.http.get<KongInfo>(`${this.base}/`); }
  status(): Observable<unknown> { return this.http.get(`${this.base}/status`); }

  services():  Observable<KongCollection<KongService>>  { return this.http.get<KongCollection<KongService>>(`${this.base}/services?size=1000`); }
  routes():    Observable<KongCollection<KongRoute>>    { return this.http.get<KongCollection<KongRoute>>(`${this.base}/routes?size=1000`); }
  plugins():   Observable<KongCollection<KongPlugin>>   { return this.http.get<KongCollection<KongPlugin>>(`${this.base}/plugins?size=1000`); }
  consumers(): Observable<KongCollection<KongConsumer>> { return this.http.get<KongCollection<KongConsumer>>(`${this.base}/consumers?size=1000`); }
  upstreams(): Observable<KongCollection<KongUpstream>> { return this.http.get<KongCollection<KongUpstream>>(`${this.base}/upstreams?size=1000`); }

  upstreamTargets(upstreamId: string): Observable<KongCollection<KongTarget>> {
    return this.http.get<KongCollection<KongTarget>>(`${this.base}/upstreams/${upstreamId}/targets?size=1000`);
  }
  upstreamHealth(upstreamId: string): Observable<unknown> {
    return this.http.get(`${this.base}/upstreams/${upstreamId}/health`);
  }
  service(id: string): Observable<KongService> { return this.http.get<KongService>(`${this.base}/services/${id}`); }
  serviceRoutes(id: string): Observable<KongCollection<KongRoute>> {
    return this.http.get<KongCollection<KongRoute>>(`${this.base}/services/${id}/routes`);
  }
}
