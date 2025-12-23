
class AccountInfo{

    private String firstName;
    private String lastName;
    private int age;

    AccountInfo(String firstName, String lastName, int age){
        this.firstName = firstName;
        this.lastName = lastName;
        this.age = age;
    }

    public String getFirstName() {
        return firstName;
    }

    String getLastName(){
        return lastName;
    }

    public int getAge(){
        return age;
    }


}


@RestController 
class AccountController{

    @PostMapping("/acount")
    getAccount(AccountInfo accountInfo){
        Create.createAccount(AccountInfo accountInfo);
    }

    @GetMapping("/count")
    createAccountget(@Param ){
        Create.createAccount(id);
    }
}


@Service
class Create{
    public static String  createAccount(AccountInfo accountInfo) {

        if(accountInfo.getFirstName().isEmpty()){
            return "erro:1";
        }
        return "suceesful:0";
    }

    public static String  createAccount(int userId) {
        return "suceesful:0";
    }
}


@RestController 
class PaymentController{

    @PutMapping("/payment")
    getAccount(A accountInfo){
        Payment.payment(String userId, double amount);
    }

}


//wallet system....

class Wallet{

    public static double bal(){
        return 30;
    }
}
@Controller
class Payment{

     public static String  payment(String userId, double amount) {

        if(amount > Wallet.bal()) {
            return "erro:1";
        }


        double db = Wallet.bal() - amount;
        return "suceesful:0";
    }
}

class Order{

}