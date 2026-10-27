-- Rode DEPOIS de criar a conta no site com o e-mail carneirohenrique@hotmail.com
-- e confirmar o e-mail (clicar no link que chega na caixa de entrada).
insert into public.user_roles (user_id, role)
select id, 'admin' from auth.users
where lower(email) = 'carneirohenrique@hotmail.com' and email_confirmed_at is not null
on conflict do nothing;

-- Conferência: deve mostrar uma linha com o seu e-mail.
select u.email, r.role from public.user_roles r join auth.users u on u.id = r.user_id;
