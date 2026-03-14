To create a superuser, run the following command:

```bash
kubectl exec -it deployment.apps/{depl-name}-taiga-backend -n {namespace} -- python manage.py createsuperuser
```

