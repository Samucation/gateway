import { Component, inject, signal, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';

interface Rota { nome: string; caminhos: string[]; metodos: string[]; plugins: string[]; }
interface Servico { nome: string; upstream: string; rotas: Rota[]; plugins: string[]; }
interface Projeto {
  id: string; nome: string; config: string; existe: boolean;
  sha?: string; services?: Servico[]; pluginsDeTopo?: { nome: string; escopo: string }[]; erro?: string;
}
interface Passo { nome: string; ok: boolean; saida: string; }

/**
 * A tela que muda a configuração do gateway.
 *
 * Ela edita o `kong.yml` DO PROJETO, nunca o `kong/kong.yml` gerado — editar o
 * gerado faz a mudança sumir na próxima geração, calada. E gravar não muda
 * nada sozinho: só APLICAR mexe no gateway, e ele desfaz tudo se qualquer
 * verificação falhar.
 */
@Component({
  selector: 'gw-projetos',
  standalone: true,
  imports: [CommonModule],
  template: `
    <h1 class="page-title">Projetos · configuração do gateway</h1>
    <p class="page-sub">
      Cada projeto tem o seu <code>kong.yml</code>. O <code>kong/kong.yml</code> do gateway é
      <strong>gerado</strong> a partir deles — por isso a edição é feita aqui, na origem.
    </p>

    @if (carregando()) { <div><span class="spinner"></span> Carregando projetos...</div> }
    @else if (erro()) { <div class="error-box">{{ erro() }}</div> }
    @else {
      <div class="toolbar">
        @for (p of projetos(); track p.id) {
          <button [class.ativo]="p.id === selecionadoId()" (click)="selecionar(p.id)">
            {{ p.nome }}
          </button>
        }
        <span class="grow"></span>
        <button (click)="recarregar()">↻ Recarregar</button>
      </div>

      @if (selecionado(); as p) {
        @if (!p.existe) { <div class="error-box">Sem arquivo em <code>{{ p.config }}</code></div> }
        @else {
          <p class="page-sub"><code>{{ p.config }}</code></p>

          <table>
            <thead><tr><th>Serviço</th><th>Upstream</th><th>Rota</th><th>Caminhos</th><th>Métodos</th><th>Plugins</th></tr></thead>
            <tbody>
              @for (s of p.services || []; track s.nome) {
                @for (r of s.rotas; track r.nome) {
                  <tr>
                    <td><strong>{{ s.nome }}</strong></td>
                    <td><code>{{ s.upstream }}</code></td>
                    <td>{{ r.nome }}</td>
                    <td>@for (c of r.caminhos; track c) { <code>{{ c }}</code> }</td>
                    <td>{{ r.metodos.length ? r.metodos.join(', ') : 'todos' }}</td>
                    <td>@for (pl of r.plugins; track pl) { <span class="badge">{{ pl }}</span> }</td>
                  </tr>
                }
              }
            </tbody>
          </table>

          @if (p.pluginsDeTopo?.length) {
            <p class="page-sub">
              Plugins declarados no topo:
              @for (pl of p.pluginsDeTopo || []; track pl.nome + pl.escopo) {
                <span class="badge muted">{{ pl.nome }} · {{ pl.escopo }}</span>
              }
            </p>
          }

          <h2 class="page-title" style="font-size:1.1rem;margin-top:1.5rem">Editar</h2>
          <textarea rows="22" style="width:100%;font-family:monospace;font-size:12px"
                    [value]="texto()" (input)="texto.set($any($event.target).value)"></textarea>

          <div class="toolbar">
            <button (click)="gravar()" [disabled]="ocupado()">Gravar</button>
            <button (click)="aplicar()" [disabled]="ocupado()"><strong>APLICAR no gateway</strong></button>
            <span class="grow"></span>
            @if (aviso()) { <span class="badge">{{ aviso() }}</span> }
          </div>

          <p class="page-sub">
            Gravar só escreve o arquivo. <strong>Aplicar</strong> gera a config unificada, pede ao Kong que
            valide, roda os dois guardas de segurança, recarrega o gateway e confere que os domínios
            respondem — e desfaz tudo se qualquer passo falhar.
          </p>
        }
      }

      @if (passos().length) {
        <h2 class="page-title" style="font-size:1.1rem">Último APLICAR</h2>
        <table>
          <tbody>
            @for (passo of passos(); track passo.nome) {
              <tr>
                <td style="width:2rem">{{ passo.ok ? '✅' : '❌' }}</td>
                <td>{{ passo.nome }}</td>
                <td><pre style="margin:0;white-space:pre-wrap;font-size:11px">{{ passo.saida }}</pre></td>
              </tr>
            }
          </tbody>
        </table>
      }
    }
  `,
})
export class ProjetosComponent {
  private http = inject(HttpClient);

  projetos = signal<Projeto[]>([]);
  selecionadoId = signal<string | null>(null);
  texto = signal('');
  sha = signal('');
  carregando = signal(true);
  ocupado = signal(false);
  erro = signal<string | null>(null);
  aviso = signal<string | null>(null);
  passos = signal<Passo[]>([]);

  selecionado = computed(() => this.projetos().find((p) => p.id === this.selecionadoId()) ?? null);

  constructor() { this.recarregar(); }

  recarregar() {
    this.carregando.set(true);
    this.http.get<Projeto[]>('/api/projetos').subscribe({
      next: (lista) => {
        this.projetos.set(lista);
        this.carregando.set(false);
        if (!this.selecionadoId() && lista.length) this.selecionar(lista[0].id);
      },
      error: (e) => { this.erro.set(String(e.message ?? e)); this.carregando.set(false); },
    });
  }

  selecionar(id: string) {
    this.selecionadoId.set(id);
    this.aviso.set(null);
    this.http.get<{ texto: string; sha: string }>(`/api/projetos/${id}/arquivo`).subscribe({
      next: (r) => { this.texto.set(r.texto); this.sha.set(r.sha); },
      error: (e) => this.erro.set(String(e.message ?? e)),
    });
  }

  gravar() {
    const id = this.selecionadoId();
    if (!id) return;
    this.ocupado.set(true);
    // manda o `sha` que veio na leitura: se o arquivo mudou no disco desde
    // então, o backend recusa em vez de sobrescrever a mudança de outra pessoa
    this.http.put<{ sha: string; aviso: string }>(`/api/projetos/${id}/arquivo`,
      { texto: this.texto(), sha: this.sha() }).subscribe({
      next: (r) => { this.sha.set(r.sha); this.aviso.set(r.aviso); this.ocupado.set(false); },
      error: (e) => { this.aviso.set(e.error?.erro ?? String(e.message ?? e)); this.ocupado.set(false); },
    });
  }

  aplicar() {
    this.ocupado.set(true);
    this.aviso.set('aplicando...');
    this.http.post<{ ok: boolean; passos: Passo[] }>('/api/aplicar', {}).subscribe({
      next: (r) => {
        this.passos.set(r.passos);
        this.aviso.set(r.ok ? 'aplicado' : 'RECUSADO — o gateway voltou ao último estado bom');
        this.ocupado.set(false);
        this.recarregar();
      },
      error: (e) => {
        this.passos.set(e.error?.passos ?? []);
        this.aviso.set('RECUSADO — o gateway voltou ao último estado bom');
        this.ocupado.set(false);
      },
    });
  }
}
