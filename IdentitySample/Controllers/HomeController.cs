using Azure;
using Azure.Identity;
using Azure.Security.KeyVault.Secrets;
using System;
using System.Collections.Generic;
using System.Configuration;
using System.Linq;
using System.Web;
using System.Web.Mvc;

namespace IdentitySample.Controllers
{
    public class HomeController : Controller
    {
        public ActionResult Index()
        {
            (bool success, string message, string secret) = GetKeyVaultSecret();
            ViewBag.Secret = secret;
            ViewBag.Message = message;
            ViewBag.KvSuccess = success;
            return View();
        }

 
        private (bool, string, string) GetKeyVaultSecret()
        {
            string keyVaultUrl = "";
            string secretName = "";
            try
            {
                var _tokenCred = new DefaultAzureCredential();
                var kvName = Environment.GetEnvironmentVariable("KeyVaultName");
                if(string.IsNullOrWhiteSpace(kvName)) kvName = ConfigurationManager.AppSettings["KeyVault.Name"];
                secretName = ConfigurationManager.AppSettings["KeyVault.SecretName"];
                keyVaultUrl = $"https://{kvName}.vault.azure.net/";
                var _secretClient = new SecretClient(vaultUri: new Uri(keyVaultUrl), credential: _tokenCred);
                var resp = _secretClient.GetSecret(secretName);
                if (!resp.GetRawResponse().IsError)
                {
                    return (true,"Value pulled directly from Key Vault with 'GetSecret':", resp.Value.Value); ;
                }
                else
                {
                    return (true,"Identity assigned properly, but failed to Get Secret!!",resp.GetRawResponse().ReasonPhrase);
                }
            }catch(RequestFailedException rfe)
            {
                if(rfe.ErrorCode == "Forbidden")
                {
                    return (false,"Unable to get secret from Key Vault!",rfe.Message);
                    
                }else if(rfe.ErrorCode == "VaultNotFound")
                {
                    return (false, $"The specified Key Vault {keyVaultUrl} was not found. Please check your environment variables for the 'KeyVaultName' key", rfe.Message);
                }
                else
                {
                    return (false, "Key Vault request error", rfe.Message);
                }
            }
            catch(Exception exe)
            {
                return (false,"Something went wrong!",exe.Message);
               
            }
            return (false,"Very odd... never really should have gotten here!","");
        }
    }
}