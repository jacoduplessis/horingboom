from django.db import models


class Note(models.Model):
    title = models.CharField(max_length=255)
    body = models.TextField(blank=True, null=True)
    source = models.CharField(max_length=50)
    inserted_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'notes'
        managed = False  # Ecto owns the schema
