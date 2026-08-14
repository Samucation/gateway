import { Routes } from '@angular/router';
import { ShellComponent } from './layout/shell.component';

// Sem `authGuard`: o console é servido em 127.0.0.1 e só ali (ver
// console/servidor.mjs). Login por Keycloak aqui daria uma sensação de
// proteção sem proteger nada — quem alcança o loopback desta máquina já pode
// editar os arquivos direto. Se um dia o console sair do loopback, a
// autenticação volta ANTES de abrir a porta, não depois.
export const routes: Routes = [
  {
    path: '',
    component: ShellComponent,
    children: [
      { path: '', redirectTo: 'aplicacoes', pathMatch: 'full' },

      // A visao geral: as cinco aplicacoes lado a lado. So virou possivel
      // depois que o log passou a registrar o host.
      {
        path: 'aplicacoes',
        loadComponent: () => import('./pages/aplicacoes/aplicacoes.component').then(m => m.AplicacoesComponent),
      },
      {
        path: 'incidentes',
        loadComponent: () => import('./pages/incidentes/incidentes.component').then(m => m.IncidentesComponent),
      },

      // A tela que EDITA. É a razão de o console existir — as de Kong abaixo
      // mostram o que está no ar, esta muda o que vai para o ar.
      {
        path: 'projetos',
        loadComponent: () => import('./pages/projetos/projetos.component').then(m => m.ProjetosComponent),
      },

      // Tráfego e abuso — lido do log de acesso do gateway.
      {
        path: 'trafego',
        loadComponent: () => import('./pages/trafego/trafego.component').then(m => m.TrafegoComponent),
      },

      // O dashboard e os alertas da base original eram do sigma-payments
      // (Prometheus, health do app, catálogo de apps). Aqui o que interessa é o
      // estado do gateway, que a própria tela de Projetos já mostra.
      // Leitura da Admin API — em DB-less ela é só leitura mesmo:
      // `POST /services` responde "cannot create entities when not using a database".
      { path: 'kong/services', loadComponent: () => import('./pages/kong/kong-services.component').then(m => m.KongServicesComponent) },
      { path: 'kong/routes', loadComponent: () => import('./pages/kong/kong-routes.component').then(m => m.KongRoutesComponent) },
      { path: 'kong/plugins', loadComponent: () => import('./pages/kong/kong-plugins.component').then(m => m.KongPluginsComponent) },
      { path: 'kong/consumers', loadComponent: () => import('./pages/kong/kong-consumers.component').then(m => m.KongConsumersComponent) },
      { path: 'kong/upstreams', loadComponent: () => import('./pages/kong/kong-upstreams.component').then(m => m.KongUpstreamsComponent) },
      { path: 'kong/status', loadComponent: () => import('./pages/kong/kong-status.component').then(m => m.KongStatusComponent) },

      { path: '**', redirectTo: 'aplicacoes' },
    ],
  },
];
